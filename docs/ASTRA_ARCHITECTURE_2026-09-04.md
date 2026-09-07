# Denial architecture and performance investigation — 2026-09-04

Requested by Logix after the initial source review. This investigation follows
work through the compositor rather than treating a count of findings as coverage.
Observations are recorded as their call paths are established. This is a review,
not an implementation change or a performance certification.

Baseline: Denial `dev` at `fdb986e`, including the existing uncommitted work.
The canonical Flutter checkout is at `119e18cfe94de7c0176e2e5105ac3f46a11f3447`;
the source lock selects `d728e61e7d835e02c453c70ae9523a40f6c03215`. The engine
`flow/` code and `shell/common/rasterizer.cc` inspected here are unchanged between
those revisions. No source lock, engine source, or runtime has been modified.
Engine paths below are relative to
`/mnt/exty/denial-flutter-fork-3.44.7/engine/src/flutter`.

## Confirmed: pixel damage is lost at the external-texture boundary

**This is a confirmed optimization opportunity in the pixel-work path.** The
architecture already avoids a Dart scene rebuild for ordinary client buffer
updates. However, the remaining raster path knows which texture changed, not
which pixels changed within it. This affects DMA-BUF clients as well as SHM
clients; it is separate from the SHM copy/upload issue in the initial review.

The evidence chain is:

1. Native surface publication produces a new buffer revision or SHM snapshot.
   It consumes remaining Wayland damage after publication
   (`compositor/src/bin/deniald/wayland_frontend/surface_pipeline.rs:175`, `:202`).
2. `ExternalTextureFrame` carries a texture ID, source/generation and sampling
   expectation, but no damage region
   (`compositor/src/bin/deniald/flutter_runtime/renderer/texture.rs:715`).
3. Output scheduling forwards texture IDs; the custom engine `render_outputs`
   ABI accepts an ID slice and no per-texture damage
   (`compositor/flutter-engine/src/lib.rs:814`).
4. For a retained scene, `FrameDamage::ComputeDamageRegion` adds every cached
   paint region of each dirty texture. For a newly diffed scene,
   `TextureLayer::Diff` also invalidates the whole dirty texture layer.
   Engine paths: `flow/compositor_context.cc:105` and
   `flow/layers/texture_layer.cc:22` in the canonical Flutter root above.
5. The engine's existing test
   `FrameDamageTest.ReusedTreeDamagesDirtyTextureWithoutDiffingLayers`
   explicitly expects the entire changed texture's rectangle
   (`flow/compositor_context_unittests.cc:166`). This is source evidence from
   an existing test; I have not run that test in this investigation.

Consequently, a client reporting a small changed rectangle inside a large
visible window still causes damage over that texture's painted region, after
transforms and clipping. The client must actually report partial damage for
preserving it to help; an application that reports full-buffer damage gives
the compositor no smaller region to exploit.

The default engine backend is Impeller GLES
(`compositor/flutter-engine/src/host.rs:196`). Its damage policy falls back to
a full output repaint when repaired buffer damage exceeds 70% of the output
(`flow/compositor_context.cc:48`). This creates a further amplification step:
full damage to a large window can become full output rasterization. For an
otherwise simple, stable scene, a 3600×2000 texture occupies about 87% of a
3840×2160 output; even a small client-reported update is enough to enter that
fallback today. This is an illustrative area calculation, not a benchmark.
Impeller's partial repaint also has resolve/blit overhead, so an area reduction
must not be translated directly into an equivalent reduction in GPU time.

### Blur makes the missing information more expensive

The retained-scene fast path invalidates a backdrop cache when any texture ID
in its input dependency list is dirty (`flow/compositor_context.cc:126`). It
cannot distinguish pixels changing under the filter from pixels changing far
away in the same texture. A dock sampling a small part of a large application
can therefore have its backdrop cache invalidated by an update elsewhere in
that application. This is a conditional example, not a measured claim about
the current desktop workload.

Damage propagation also expands regions through intersecting readback/filter
dependencies (`flow/diff_context.cc`, `DiffContext::ComputeDamage`). Preserving
client damage must be accompanied by region-aware cache invalidation; sending
smaller rectangles while retaining ID-only cache invalidation would leave
part of the avoidable work in place.

### Recommended architectural change

Carry a bounded damage region with each published texture generation, through
the native mailbox and engine ABI. Retain enough transform/clip metadata in
Flutter to map that region into each occurrence of the texture in each output.
Flutter must remain the authority on scene transforms, effects and visible
sampling; reconstructing a competing visual scene in Rust would complicate
the design unnecessarily.

Correctness requirements include surface-to-buffer mapping, viewport and scale
changes, old/new geometry damage, accumulation over dropped or deferred buffer
generations, multiple texture occurrences, outputs presenting at different
rates, and recycled output-buffer history. Unknown mappings and excessive
region complexity should fall back to full texture damage. A buffer's valid
damage must not be discarded merely because one output has consumed it.

Start by measuring client-reported damage area versus texture paint area,
then propagated frame damage, repaired buffer damage, cache invalidations,
GPU time and deadline misses. That establishes whether sparse client updates
are common enough in representative workloads to justify the implementation.
The current code establishes amplification; it does not establish a speedup.

## Confirmed: visibility does not fully control client-driven render demand

Denial already receives visibility information from Flutter and uses it to
decide whether a queued texture must wait to be sampled before advancing.
That is a sound buffer-lifetime policy. It is not yet a render-demand policy:

- `wayland_frontend/scene_input.rs:288` sends requested frame callbacks to
  windows belonging to the ticking output without consulting the published
  visible-window set. Workspace switching updates the active workspace while
  retaining mapped windows (`wayland_frontend/workspace.rs:145`).
- `renderer/handler.rs:569` reports changed texture generations even when
  `expects_sample` is false. `output_runtime.rs:247` assigns textures to
  outputs by window geometry; `:285` dirties those outputs on changes without
  a visibility condition. These paths are below
  `compositor/src/bin/deniald/flutter_runtime/`.
- `ExternalTextureSlot::advance` allows an unseen texture to advance, so this
  need not deadlock. However, advancing its generation still enters the
  output-render path.

An animating application on an inactive workspace can therefore keep receiving
frame opportunities and submitting updates that authorize composition even
when Flutter has no visible use for its texture. The engine may find no paint
region for that texture; that does not eliminate the upstream work. This is a
confirmed scheduling path, not a measured frequency in the user's session.

Use scene-generation-bound sampling demand to distinguish a mailbox update
from a reason to rasterize an output. Retain live demand for overview previews,
minimize/restore transitions and effects that sample the window. A minimized
window is not automatically unsampled, and input hit testing alone is not a
sufficient visibility authority. Treat frame-callback pacing as an associated,
separate policy: hidden clients can receive reduced opportunities without
making restores or client progress depend on a render that will never happen.

This does not establish an occlusion-culling defect for every covered window.
Transparent and backdrop-filtering foreground surfaces may legitimately need
the pixels behind them. General occlusion needs scene/effect evidence.

## Confirmed: a Flutter frame request dirties every powered output

`frame_scheduler.rs:290` calls `mark_all_dirty` when a Flutter-requested frame
is admitted. The engine then projects the new shared scene into physical
output layer trees (`shell/common/rasterizer.cc:438`). Independent output
clocks preserve cadence, but do not prove that each output's pixels changed.

Even when damage computation finds no new pixels for an output, the normal
raster path reaches `frame->Submit()` (`rasterizer.cc:1187`, `:1213`). The
native output broker accepts empty damage as a ready frame
(`flutter_runtime/output_pipeline.rs:279`). Buffer-age repair may itself be
nonempty even when the displayed result would be unchanged.

This means shell animation confined to one monitor can generate avoidable
transactions for another monitor. It does not mean the other monitor is
necessarily repainted in full: clipping and damage propagation still apply.
Measure zero-frame-damage transactions per output before prioritizing this.

The useful next contract is explicit completion without a new presented image
when an output's visible result has not changed. It must retire the correct
authorization, advance retained scene metadata, preserve any accumulated
damage and handle required capture/initialization work. Simply returning early
from rasterization risks leaving the current ownership state machine stuck.

## Confirmed: retained scenes still incur a recursive preroll on each raster

This is a separate CPU optimization candidate, raised by Logix's observation
that a small cursor movement produces a CPU burst. That observation alone
cannot establish that the desktop's pixels were all repainted. The source
does establish scene preparation work that is not proportional to the number
of changed pixels:

- `CompositorContext::ScopedFrame::Raster` always calls `LayerTree::Preroll`
  after damage calculation (`flow/compositor_context.cc:275`), including when
  the scene and its diff metadata were reused.
- `ContainerLayer::PrerollChildren` calls `Preroll` for every child, recomputes
  aggregate bounds and combines rendering flags
  (`flow/layers/container_layer.cc:135`).
- Clip layers also recurse through children during preroll rather than
  stopping at an empty clip (`flow/layers/clip_shape_layer.h:44`). Painting
  subsequently performs its own culling
  (`flow/layers/container_layer.cc:182`, `flow/layers/layer.h:227`).
- Denial projects the shared source root into each selected physical output,
  so this preparation is repeated for each output raster. Independent output
  buffers do not, by themselves, isolate this CPU traversal cost.

The cursor path already avoids ordinary widget rebuild/layout work for its
child: `ShellCursorHost._setPosition` updates a notifier, and
`RetainedTranslation` updates a render transform. See
`dart_shell/lib/src/widgets/shell_cursor.dart:372` and
`dart_shell/lib/src/widgets/retained_translation.dart`. Crossing output scales,
first visibility, hover responses and other state changes can require more
work. This is not a measurement isolating the cursor's CPU burst.

### Proposed specialization: reuse prepared state for unchanged subtrees

The engine already retains scene layers and damage metadata. Extend that
retention to eligible preroll results: bounds, renderable-state flags and
dependency summaries. For a texture-only update with unchanged geometry,
reuse the prepared scene state. For a small transform update, recompute the
changed branch and necessary ancestor state while reusing unaffected branches.
Pixel damage and actual paint still need independent handling.

Begin with a narrow, auditable set of layers whose preparation is reusable;
use ordinary preroll for everything else. This is not safe as an unconditional
"skip preroll if the root pointer is unchanged" shortcut. Context-sensitive
filters, platform views, output-relative geometry, device scale, rendering
resources and output configuration can invalidate preparation. Denial shares
layer objects across outputs, and preroll writes mutable fields on those
objects: a cache must prevent one output from reusing state left by another.

Measure preroll duration and visited-layer count separately from diffing,
display-list dispatch, command encoding, GPU time and presentation. If the
CPU burst is dominated by driver submission, optimizing preroll alone will
have little effect. Conversely, expensive repeated preparation of unchanged
subtrees can be reduced even when pixel-damage rectangles are already ideal.

### Caching draw instructions is not caching rendered pixels

Repaint boundaries and retained display lists can avoid Dart paint recording
without removing raster-side preparation or all command encoding. Denial's
physical-output path explicitly passes `ignore_raster_cache = true`
(`shell/common/rasterizer.cc:1182`). The old Ganesh raster-cache mechanism is
therefore not a source of pixel reuse on that path, and enabling it is not
an Impeller optimization. Existing Denial backdrop caches are a separate
mechanism and should be preserved.

The Impeller GLES output path builds a frame display list and calls
`RenderToTarget` (`shell/gpu/gpu_surface_gl_impeller.cc:172`). That function
dispatches it through a first pass collecting backdrop metadata and then a
rendering dispatcher (`impeller/display_list/dl_dispatcher.cc:1482`). These
passes operate on the recorded, culled frame, not necessarily every object in
the desktop. They are additional CPU stages to distinguish from the recursive
layer preroll and from GPU fragment work.

If measurement identifies repeated expensive rendering of stable decorations
or effects, consider bounded caches of those rendered results, with explicit
content, transform/scale and dependency invalidation. A cache can cost more
than the work it avoids through memory traffic, offscreen passes and eviction;
there is no justification here for caching every window or replacing the
entire scene with a fullscreen texture on every update.

## Architectural judgment and next step

### Measured cursor workload, 2026-09-04

The [saved baseline](benchmarks/cursor/baseline-2026-09-04/README.md) uses a
user-prepared maximized transparent glass Kitty with static contents. Three
30-second circular-cursor runs consumed 16.00–16.97% of one logical CPU, with
mean raster durations of 2.03–2.08 ms and i915 render-engine busy counters of
46.47–48.80%. A separate CPU profile concentrated self samples in graphics
driver and command submission work; it did not establish inclusive preroll
cost. This evidence changes the first experiment's priority.

`DiffContext::ComputeDamage` expands overlapping damage to the entire readback
dependency, even for a change painted above the backdrop. Impeller already
caches unchanged filtered backgrounds, but damage planning does not consult
that cache. The first experiment connects these stages: omit a readback
dependency only when the exact current backdrop version has a snapshot covering
the filter's complete paint extent, pinned through submission. Missing,
insufficient, or invalidated snapshots keep conservative repair. Shared filters
and ancestor image-filter transformations also keep that path initially.

The [experiment](benchmarks/cursor/backdrop-damage-experiment.md) passed its
flow and targeted OpenGLES tests and the user's glass validation. Its first
[three-run comparison](benchmarks/cursor/backdrop-damage-2026-09-04/README.md)
still produced full-output damage. CPU and raster timings were slightly lower,
but that does not establish that the intended optimization worked.

Separate traces then found snapshots present but rebuilt every cursor frame.
The glass renderer truncates fractional material dimensions when allocating
its texture, leaving a snapshot too small for the next coverage check. The
first damage patch also compared top-left Flow coordinates to snapshots after
the embedder's deferred vertical flip. The follow-up fixes those boundaries
and preserves floating-point filter extents for cache queries. After user visual
validation, its [three-run comparison](benchmarks/cursor/snapshot-coverage-2026-09-04/README.md)
reduced CPU by 51%, mean raster by 68% and GPU render activity by 89%.
Average frame damage fell to 1.99%. The remaining raster preparation and periodic
full-damage updates were then profiled separately. Direct stage probes put scene
preparation and recording at about 117 µs, with large spikes in backend
rendering. A cache-admission trace confirmed repeated filter evaluation after
occasional changes: one evaluation without retaining the result, then another
to populate the cache. The [refresh experiment](benchmarks/cursor/backdrop-refresh-experiment.md)
uses confirmed cache reuse to admit a replacement immediately, while returning
continuously changing versions to delayed admission. After user visual validation,
its [three-run comparison](benchmarks/cursor/backdrop-refresh-2026-09-05/README.md)
reduced raster p99 from 2832 to 1331 µs and full-frame redraw frequency by 41.3%.
Average CPU and raster time were essentially unchanged, p95 rose 5.1%, and
cadence remained unchanged. These limits are recorded alongside the reductions;
the cause of the existing cadence behavior remains unproven.

Keep the native ownership of Wayland/KMS resources, Flutter's ownership of the
visual scene, autonomous client-texture updates, and independent physical
output pools. Those choices provide the foundation needed for these changes.
The opportunities include both missing precision in information crossing
boundaries and repeated preparation within the renderer. Neither establishes
that the principal ownership split should be replaced.

The first experiment should separate CPU scene preparation from pixel work
under ordinary composition. Use existing render-audit frame/buffer damage and
GPU timings; add bounded timings/counts for preroll and command preparation,
client damage, generation coalescing and backdrop cache invalidations.
Do not publish window titles or pixel contents in this
telemetry. Compare equivalent user-driven workloads: a sparse application
update, full-surface motion, an animation on one of two outputs, and an
application that leaves the visible scene. The user owns visual validation
and initiates visible test workloads.

If repeated scene preparation dominates, prototype selective preroll reuse
first. If applications mainly submit small damage and the engine expands it,
prioritize generation-aware damage transport. If applications report
full-buffer damage, that particular pixel optimization has little scope for
those applications; focus on measured raster costs and eligible direct
presentation instead.
`docs/direct_scanout.md` already plans the latter. It is a complementary
optimization for eligible full-output workloads, with composition retained
when the shell must sample client pixels.

Success means lower CPU/GPU work and fewer deadline misses for the same visual
result and update cadence. A reduced frame count or a smaller reported damage
rectangle alone is not sufficient evidence. The initial 15 findings were not
an exhaustion of the architecture, and this investigation is not a claim that
all remaining performance opportunities have been found.

## Passive runtime sample

A 12-second user-space CPU sample of the existing local session collected
445 samples with no reported loss. Approximately 32% landed in the Flutter
engine on the raster thread; another 31% in the graphics driver across raster
and driver worker threads. Dart UI-thread engine/application code accounted
for about 8%. An independent eight-second counter capture recorded 1.06 CPU
seconds in user space. These are brief, uncontrolled samples, not idle power
measurements or benchmark results. They support examining raster work but
cannot identify the amount attributable to damage amplification.

Artifacts are in `/tmp/denial-architecture-profile-20260904/`. The compositor
was already running from a replaced executable (`/proc/1822/exe` reports
`deniald (deleted)`), so the profile must not be treated as an exact build of
the current working tree. No session restart, visible test event, screenshot,
or application launch was performed.
