# Denial Multi-Monitor Per-Output Rasterization Plan

## Review status

The architectural review began from the exact Flutter fork pinned by
`prebuilt/flutter-engine/SOURCE_LOCK.json`: `denialwm/flutter`, branch
`denial/3.44.7-r1`, revision
`83f9bff17d53a8bb071b07b8bb740d3f25e0fed2`.

The implementation described below is now present in Denial and in the
canonical Flutter fork. The approved checkpoint commits the engine changes and
advances the immutable source lock to that exact revision, so normal
lock-driven builds consume the same implementation that was validated on the
dual-output system.

The central direction is correct: keep one Dart scene and rasterize that scene
independently for every physical output. The original draft, however,
underestimated the coordinate, lifetime, topology, and presentation contracts.
Those are not follow-up polish. They are part of the architecture and must be
implemented before the atlas path can be retired.

The current atlas design rasterizes Flutter once and lets KMS scan different
rectangles from that one framebuffer. It cannot make the same shell text native
to both a 1.0x and a 1.5x output. Per-output backing stores eliminate that
forced reuse: each output gets pixels rasterized at its own exact physical size
and scale, while Dart continues to build one logical desktop scene.

## Non-negotiable invariants

1. Dart owns exactly one `FlutterView`, one widget tree, one semantics tree, and
   one logical desktop scene.
2. A Dart frame publishes one immutable latest scene. Each output consumes the
   newest available scene at its own next authorized tick; one output frame is
   internally consistent, but unrelated CRTCs never wait for an atlas-wide
   scene barrier.
3. Every powered output receives a backing store whose dimensions exactly
   match its transformed physical mode. KMS presents that store at 1:1; it does
   not repair Flutter scaling.
4. Fractional scale remains exact as `scale_120`. It is never reconstructed
   from a rounded integer or made authoritative as a `double`.
5. Output translation, scale, rotation, and reflection are expressed by one
   tested projection contract. No second crop or scale is hidden in KMS.
6. Output configuration is versioned and applied atomically on the raster
   thread. A raster transaction never mixes two topology generations.
7. Client buffers, render targets, and fences remain leased until their actual
   GPU and presentation consumers have finished or been explicitly skipped.
8. Each CRTC remains an independent Volition stream. A slow or backpressured
   output cannot stall unrelated outputs or force them onto its refresh clock.
9. The initial correctness path uses full per-output repaint and explicitly
   ignores the raster cache. Damage and cache optimization return only after
   the projection and lifecycle tests pass.
10. Synthetic render-view IDs live in a reserved namespace and can never
    collide with real Flutter view IDs.
11. One `OutputTimeline` per powered output is the sole authority for raster
    deadlines and presentation targets. KMS completion is feedback and may
    retire resources, but it cannot create, postpone, or rephase a render tick.

## Architecture

`Animator::Render()` remains unchanged. It still receives the one real view:

```text
Dart
  |
  v
Animator::Render(view0, desktop_layer_tree)
  |
  v
LayerTreeTask(view0)
```

The Denial-specific expansion belongs in `Rasterizer::DrawToSurfacesUnsafe()`
before Flutter's normal per-task draw loop. The latest scene is projected for
every output, but only the outputs authorized by the current clock tick enter
the draw loop:

```text
LayerTreeTask(view0, latest scene generation G)
  |
  +-- due output A --> draw task(render_id A, 1920x1080, 120/120)
  +-- output B --> retain latest task(render_id B, 3840x2160, 180/120)
  `-- output C --> retain latest task(render_id C, rotated size, scale_120)
```

Every fresh task for real `view0` is expanded across the current output
snapshot. Selected projections raster immediately; unselected projections
replace that output's pending latest task and raster at its own later tick.
External-texture-only work directly consumes the newest pending or last
successful projected task without asking Dart for another frame. A task whose
negative render ID already identifies a synthetic output is never expanded
again. Once fan-out is active, no stale `view0` `ViewRecord` remains available
across an output-configuration generation change.

Synthetic render IDs exist only below the rasterizer boundary. They are not
registered through `FlutterEngineAddView`, exposed through
`PlatformDispatcher.views`, or used for input, semantics, or Dart layout.

## Coordinate contract

This is the most important correction to the original draft.
`LayerTreeTask.device_pixel_ratio` does not scale the layer tree during paint.
It is forwarded to external-view/compositor metadata. Flutter's framework has
already installed `ViewConfiguration.toMatrix()` at the root of the real layer
tree, so the source tree is already expressed in `view0` physical pixels at the
atlas DPR.

The native output description therefore uses these spaces:

- `source_*`: the output rectangle in `view0` physical-pixel coordinates;
- `target_width/height`: transformed output framebuffer pixels;
- `scale_120`: the output's exact Wayland scale;
- `transform`: the complete Wayland output transform;
- `configuration_generation`: the topology snapshot which produced all of the
  above.

Conceptually, the output wrapper and plane apply:

```text
output-target pixel = scale(target_extent / source_extent)
                    * translate(-source_physical_origin)
                    * source-tree pixel
panel pixel = KMS transform * output-target pixel
```

The implementation must encode this with Flutter's actual matrix convention
and prove it by mapping corners and interior points. The textual multiplication
order above is not a substitute for those tests. Flutter creates the output's
transformed native pixel extent; the plane applies rotation/reflection once at
1:1. It must never be duplicated in the layer-tree projection.

The projected tree is conceptually:

```text
Output LayerTree (exact transformed physical size)
`-- ClipRect(output framebuffer bounds)
    `-- Transform(output projection)
        `-- desktop scene root
```

The root can initially be shared because `LayerTree` accepts a
`shared_ptr<Layer>` and `ContainerLayer::Add()` does too. That proves lifetime,
not semantic safety. Preroll, diff, paint bounds, retained-layer metadata, and
cache metadata can be mutated during traversal. Shared traversal is accepted
only after focused engine tests cover text/display lists, textures, clips,
opacity, backdrop filters, and retained layers under at least two projections.
If those tests expose shared mutation, the clean solution is immutable display
list replay or isolated per-pass metadata—not locks around layer traversal.

`PrepareFlutterView(frame_size, dpr)` currently has no view ID, despite
`DrawToSurfaceUnsafe()` knowing it. The embedder also obtains one global GL
surface transformation. That is insufficient for output-specific dimensions.
The fork must carry the render view ID into preparation. Denial uses an identity
backing-store orientation contract: the Flutter projection performs only crop
and exact native scaling, while KMS owns the configured output transform. There
must be exactly one orientation operation and exactly one Y inversion.

## Engine API

The custom ABI should follow Denial's existing versioned embedder extensions
and copy the complete array before posting it to the raster thread. A
representative contract is:

```cpp
typedef enum {
  kDenialFlutterOutputNormal,
  kDenialFlutterOutputRotate90,
  kDenialFlutterOutputRotate180,
  kDenialFlutterOutputRotate270,
  kDenialFlutterOutputFlipped,
  kDenialFlutterOutputFlipped90,
  kDenialFlutterOutputFlipped180,
  kDenialFlutterOutputFlipped270,
} DenialFlutterOutputTransform;

typedef struct {
  size_t struct_size;
  int64_t render_view_id;
  uint64_t configuration_generation;

  double source_physical_x;
  double source_physical_y;
  double source_physical_width;
  double source_physical_height;

  size_t target_width;
  size_t target_height;
  uint32_t scale_120;
  DenialFlutterOutputTransform transform;
} DenialFlutterRenderOutput;

FlutterEngineResult DenialFlutterEngineSetRenderOutputs(
    FlutterEngine engine,
    const DenialFlutterRenderOutput* outputs,
    size_t output_count);

FlutterEngineResult DenialFlutterEngineRenderOutputs(
    FlutterEngine engine,
    const int64_t* render_view_ids,
    size_t render_view_count,
    const int64_t* texture_identifiers,
    size_t texture_count,
    bool rebuild_scene,
    uint64_t frame_start_time_nanos,
    uint64_t frame_target_time_nanos);
```

The public ABI rejects duplicate or non-negative IDs, zero scale, zero sizes,
non-finite or non-positive source rectangles, mixed or zero generations,
unknown transforms, oversized target dimensions, malformed structures, and
invalid pointer/count combinations. Denial derives source bounds and target
dimensions from one validated topology snapshot before calling the ABI, which
is where cross-field geometry consistency is established. Empty output lists
are valid in the engine and collect reusable synthetic view records.

The API posts one owned `RenderOutputConfiguration` to the raster task runner.
The rasterizer swaps the whole configuration between transactions. It never
mutates an output entry in place.

`DenialFlutterEngineRenderOutputs` is the only raster authorization operation
in the KMS path. It copies a non-empty set of negative render-view IDs and the
coalesced dirty texture IDs. With `rebuild_scene=true`, it installs the
selection before Rust delivers the pending Flutter `AwaitVSync` baton. With
`rebuild_scene=false`, it posts a direct raster-runner replay of the latest
projected scene and never wakes Dart. The supplied physical timestamps give
that direct pass the same output-clock timing contract as a framework frame.

## Topology lifecycle

`CollectView(render_view_id)` is useful but removal alone is insufficient. A
render record is invalid whenever size, source rectangle, scale, transform, or
configuration generation changes. Changed and removed IDs must have both their
`ViewRecord` and compositor backing-store cache collected before the new
configuration can reuse that ID.

A topology update follows this sequence:

```text
Rust validates complete topology generation T+1
  -> engine copies T+1
  -> raster thread reaches transaction boundary
  -> changed/removed render records are collected
  -> T+1 becomes current
  -> Dart is scheduled for a fresh frame
  -> only T+1 output tasks may be published
```

The synthetic ID namespace must be stable across ordinary frames and unique
across hotplug. IDs should derive from Denial output identity through an
explicit allocator, not by casting a connector index into `FlutterViewId`.

## FlutterCompositor migration

The old global `fbo_with_frame_info_callback`/`present_with_info` atlas path
cannot identify the render view and cannot remain the primary path.
`FlutterCompositor` is the correct boundary:

- `create_backing_store_callback` receives `FlutterBackingStoreConfig.view_id`;
- `present_view_callback` receives `FlutterPresentViewInfo.view_id`;
- Flutter already owns a render-target cache per view ID.

Migration happens before fan-out. First enable `FlutterCompositor` for one
atlas-sized implicit output and prove create, present, collect, GL state, fence,
and shutdown behavior without changing raster topology. Then add the per-output
pools and engine fan-out. This isolates compositor callback defects from
projection defects.

Every output pool is keyed by stable render ID plus configuration generation.
A backing store from an old generation is never returned for a changed output.
The backing store carries all native ownership required to import it into KMS;
the present callback publishes a typed ready lease rather than an unstructured
FBO index.

## Raster transactions and external textures

One central scheduler owns all physical raster authorization. It maintains one
absolute `OutputTimeline` and one dirty record per powered output, but uses one
event-loop timer and one decision point:

```text
client commit -> mark every intersecting output dirty(texture ID)
Flutter AwaitVSync -> mark every output dirty(scene rebuild)
timer wake -> advance all output timelines from their previous deadlines
due + dirty + native target available -> authorize output
one producer transaction -> raster the authorized set
each completed output -> ready lease carrying the same tick/target -> Volition
```

Each emitted tick contains its output ID, output-local wrapping sequence,
nominal render deadline, refresh interval, and following presentation target.
Late event-loop wakes collapse missed periods but preserve the original
absolute phase. The next deadline is derived only from the preceding deadline;
it is never reconstructed from `Instant::now()` or a page flip. A tick consumed
while Flutter has no free producer remains consumed, and the still-dirty output
waits for its next timeline edge rather than rendering opportunistically in the
middle of a period.

Wayland frame callbacks are sent once for each emitted output tick, carry that
tick's nominal deadline in the protocol clock, and request client content for
the following target. Flutter `AwaitVSync`, app commits,
producer wakeups, and KMS events only mutate pending state or wake the event
loop. They do not authorize rendering.

Damage uses output-local monotonically increasing serials. Raster completion
clears an output only when its captured serial is still current, so a client or
Flutter update arriving during GPU work cannot be erased by an older result.
If several due outputs are available on the same timer wake, they coalesce into
one producer transaction; this is an optimization, not an atomic publication
requirement. A blocked output is omitted and remains dirty.

External texture sources remain latest-value mailboxes. Authorization advances
only the dirty texture IDs selected by the scheduler. If a queued successor
cannot advance because the current generation has not yet been sampled, that
texture immediately re-dirties its intersecting outputs with a newer serial.
Each raster pass owns its sampled-buffer holds and release fence; the retained
current source remains valid for a slower output which consumes the same
generation later. Topology replacement discards deferred synthetic tasks and
forces a new configuration generation.

## Volition and physical presentation

Per-output rasterization must use Volition as the presentation architecture,
not merely call it after a global frame barrier.

Each powered output remains one independent `OutputPipeline` and one Volition
stream. A completed per-output backing-store lease enters that output's latest
ready mailbox with:

```text
render ID
scene generation
topology generation
framebuffer lease
render fence
damage
optional screenshot request
render completion time
timeline tick sequence
timeline render deadline
timeline presentation target
```

Volition preserves the existing bounded lookahead model:

- the first ready generation may enter KMS immediately with `IN_FENCE_FD`;
- the next generation may occupy the lookahead lane only after its render
  fence signals;
- no stream retains more than
  `MAX_IN_FLIGHT_COMMITS_PER_STREAM` generations;
- backpressure replaces only that output's unsubmitted ordinary mailbox entry;
- screenshot-tagged generations remain exact and cannot be superseded;
- page-flip completion retires that output's framebuffer lease and drives
  Wayland presentation feedback for surfaces visible on that output.

There is no complete-ready-set barrier. Flutter's compositor may finish one or
several output views in a raster transaction; the Rust broker converts every
finished view directly into its own ready lease. The output scheduler validates
and publishes that lease without inspecting unrelated outputs. Volition uses
the presentation target carried from `OutputTimeline`; it does not maintain or
reconstruct a second `next_presentation_at` clock. The first generation may
enter KMS immediately with its fence so the kernel can stage it for the target;
lookahead work waits until the same explicit target minus the bounded submit
lead. This preserves one latest Dart scene while allowing 60 Hz, 120/144 Hz,
and VRR streams to progress independently.

The former scheduler's atlas-wide ready fence and index fan-out have become
per-output ready leases. Pool sizing is local
to each output stream: scanning, submitted/lookahead, ready, plus a render
target. `OutputTimeline` owns timing; Volition owns deadline execution and
atomic submission. Denial continues to own scene choice, fences, leases,
failure recovery, screenshots, and feedback.

## Damage, caches, and screenshots

The first correct implementation uses full repaint for every affected output
and passes `ignore_raster_cache = true` through preroll, paint, and raster.
Using `FlutterCompositor` does not implicitly guarantee that all raster caches
are disabled.

After correctness is established:

1. keep previous projected trees per output;
2. compute damage in output pixel space;
3. restore per-output partial repaint;
4. restore only caches whose keys include projection/scale identity;
5. audit backdrop readback and retained-layer behavior again.

Atlas screenshots cannot survive unchanged. Output capture copies the exact
per-output framebuffer. A logical-desktop screenshot either composes the
per-output captures into a virtual atlas with declared scale semantics or
rasterizes an explicit capture target. It must never silently read a retired
global atlas.

Cursor ownership must also stay explicit. A hardware cursor is captured or
omitted according to screenshot policy; it must not accidentally become
Flutter damage on every output.

## Dart-side scale policy

Per-output rasterization changes how one scene is sampled; it does not give
Dart a different `MediaQuery.devicePixelRatio` for each output. Any Dart
geometry that asks the global DPR for “one physical pixel” remains globally
wrong in a mixed-scale desktop.

The current `desktopPixelAlignedWindowFrame` and one-physical-pixel border
policy therefore need an audit. Output-neutral logical geometry stays in Dart.
Per-output pixel snapping and hairline realization belong in the output
projection/raster pass, or in native metadata which can be applied separately
for each render target. A window spanning outputs cannot have one Dart rect
rounded two different ways before fan-out.

## What this architecture can and cannot promise

Flutter shell text and vector content can be rasterized natively for every
output, including fractional scale. A Wayland client surface is different: it
has one current client buffer and one preferred scale at a time. Kitty can
submit a new buffer after its owning output changes, but one Kitty buffer
cannot simultaneously be native at both 1.0x and 1.5x while crossing the
boundary.

Therefore the acceptance contract is:

- shell glyphs, borders, and vector content are native to every output;
- a client buffer is sampled once per output with the exact output projection;
- the owning output uses the client's best current buffer without an
  additional atlas resample;
- the non-owning portion may resample until the client commits for its new
  preferred scale;
- changing ownership cannot corrupt, double-release, or tear the client
  generation.

“Window crossing boundary is perfect” is not a technically valid criterion
for arbitrary Wayland clients and is removed from the plan.

## Tests required before optimization

Engine tests must establish:

- exact projection at 120, 150, 180, and 240 scale units;
- every rotation and reflection, including swapped target dimensions;
- two output passes over text, display lists, texture layers, clips, opacity,
  backdrop filters, and retained layers;
- fresh view0 expansion versus reused output-task pass-through;
- changed/removed topology collection and stale generation rejection;
- failed/retried pass closure without leaking an output authorization;
- backing-store cache separation by render ID and topology generation;
- one external texture generation retained through every output pass.

Denial unit tests must establish:

- per-output dirty/tick authorization and Flutter/app coalescing;
- stale completion serials cannot clear newer output damage;
- partial raster transactions publish every completed output independently;
- independent Volition mailboxes and lookahead lanes;
- per-output render-fence handling and pool retirement;
- latest-value replacement on one output without affecting another;
- exact screenshot generations;
- hotplug/DPMS while output raster or page flips are in flight;
- Wayland feedback and client-buffer release after the final real consumer.

The user performs visual and hardware validation. Automated tests prove
contracts and lifetime; they do not claim that a driver, panel, or glyph looks
correct.

## Implementation order

1. Introduce typed render-output identity, topology generation, output-local
   dirty serials, and per-output ready-lease models in Denial.
2. Activate `FlutterCompositor` on the existing single atlas-sized target and
   preserve current presentation behavior.
3. Replace atlas-index assumptions in the runtime/scheduler boundary with
   output-keyed leases while keeping one output configured.
4. Add the versioned engine render-output ABI and raster-thread configuration
   transaction.
5. Add view-aware preparation/surface orientation and exact projection tests.
6. Add fresh-view0 fan-out with full repaint and raster cache explicitly
   ignored; remove stale view0 reuse state.
7. Add per-output backing-store pools and independent ready-frame publication.
8. Route each ready lease into its independent Volition stream and retire it on
   page-flip completion.
9. Add the single timer decision point, per-output refresh timelines, latest-scene
   deferral, and texture-only direct replay.
10. Complete external-texture leases, retries, topology changes, DPMS,
    screenshots, capture, shutdown, and recovery paths.
11. Audit Dart DPR-dependent geometry and move per-output snapping to the
    raster/output boundary.
12. Only then restore damage, retained rendering, and raster caches per output.

Line-count estimates are deliberately removed as an architectural decision
tool. The C++ fan-out may remain small, but the production change necessarily
crosses the engine ABI, rasterizer, external-view embedder, Rust runtime,
buffer broker, output scheduler, Volition handoff, topology lifecycle, capture,
and Dart scale policy. Completeness and ownership clarity matter more than a
small diff.

## Completion definition

Implementation is complete when the global atlas is no longer the source of
physical output pixels; every output is rasterized to an exact native backing
store; one Dart scene remains authoritative; texture and backing-store leases
are correct across every pass; topology changes are atomic; and independent
Volition streams present coherent scene generations without cross-output
clock coupling.

The architecture is still compact in concept: one scene, N projections, N
native backing stores, N independent presentation streams. The engineering
must make those four statements true all the way through the stack.

## Implementation status — 2026-08-19

The source implementation now follows the single-controller architecture.
Flutter presentation does not allocate, render, or scan out a shared desktop
framebuffer. The logical `AtlasPlan` remains the coordinate model for the one
Dart view and the virtual canvas for desktop capture; physical pixels come only
from native per-output backing stores.

The active frame path is linear:

1. Scene synchronization records changed external-texture IDs against every
   output intersecting the window.
2. Flutter `AwaitVSync` demand marks all powered outputs dirty; app commits mark
   only their intersecting outputs dirty.
3. One event-loop timer advances each output's absolute refresh-rate timeline.
4. Due dirty outputs with free native targets are authorized together. Flutter
   and app demand coalesce into that one decision.
5. A Flutter rebuild publishes one latest scene. The engine rasters selected
   projections now and retains the newest projection for every unselected
   output. App-only work replays those latest projected scenes without Dart.
6. Every completed output leaves Flutter's broker independently, retains its
   dirty serial and exact timeline request, and enters only its own Volition
   stream.
7. Publication clears output damage only if no newer update superseded the
   serial captured by that raster.
8. Page flips retire output generations and report Wayland presentation only;
   they never inject a tick or move a timeline deadline.

The cadence correction completed on 2026-08-19 removes the former competing
authorities. `DisplayClock.presented_tick` and presentation-driven rephasing no
longer exist. `OutputPipeline.next_presentation_at` and its refresh-derived
prediction no longer exist. The request emitted by `OutputTimeline` is copied
unchanged into the native backing-store authorization, returned with the ready
output frame, and consumed by that output's Volition lane. Rendering targets
the edge following the authorization deadline, leaving one complete nominal
interval for client production, Flutter raster, fence signaling, and KMS
submission.

Implemented supporting contracts include stable negative render IDs, exact
`scale_120`, native transformed target sizes, topology generations,
output-local backing-store pools and fences, view-aware OpenGL origin
conversion, screenshot targeting, client-buffer sampling holds, topology/DPMS
recovery, and output-local page-flip retirement. Full repaint and conservative
synthetic-output cache behavior remain the correctness baseline.

Automated verification completed for this revision:

- production Flutter/KMS Rust code passes Clippy with warnings denied;
- the Denial core suite passes 15 tests, denialctl passes 9 tests, the deniald
  suite passes 417 tests with 2 deliberately ignored, and the Rust engine ABI
  suite passes 13 tests;
- the canonical Flutter fork builds `libflutter_engine.so` and both focused
  test binaries;
- four focused rasterizer tests pass, including selected-output raster with a
  deferred latest scene for the other output;
- two focused embedder ABI tests pass, including malformed output-render
  transactions.

The source lock is intentionally unchanged because this implementation obeyed
the explicit no-Git constraint. The directly built canonical engine is valid
for the requested `.18` validation, but immutable lock-driven packaging cannot
consume these engine edits until a later provenance step commits the canonical
fork and advances `SOURCE_LOCK.json`.

No runtime or visual claim is made here. The user owns validation of cadence,
glyph quality, mixed 1.0x/1.5x motion, rotated outputs, driver behavior, and
hardware presentation. Per-output partial-damage and raster-cache optimization
remain later work after that validation.
