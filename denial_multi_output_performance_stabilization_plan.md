# Denial Multi-Output Performance Stabilization Plan

## Status and scope

Per-output native rasterization is architecturally correct and fixes mixed-scale
output quality, but the current implementation still contains transitional
correctness fallbacks. On a dual-2560x1440 system running at approximately
240 Hz and 100 Hz, both outputs miss their refresh targets while GPU power,
VRAM use, and CPU use are much higher than the previous atlas architecture.

This is not accepted as an inherent cost of per-output rasterization. Denial
must retain independent native output rasterization while removing duplicated,
discarded, and full-frame work. The design must remain suitable for displays up
to 300 Hz.

The user owns visual and hardware validation. Implementation proceeds one
coherent change at a time, and the next behavioral change is not deployed for
validation until the user has evaluated the previous one. Automated tests and
static checks may prove contracts, but they do not replace the user's cadence,
power, scaling, and image-quality assessment. UI interaction is never
automated.

The implementation was developed experimentally without Git. After hardware
validation, the accepted state was captured as a reproducible checkpoint in
the canonical Flutter fork and Denial's `dev` branch.

## Implementation progress

- **Phase 1 implemented, built, and accepted by the user.** The fastest powered
  output is now the sole authority for Dart `AwaitVSync` delivery and global
  frame time. Slower output ticks can rasterize the newest retained projection,
  but cannot consume the Flutter baton. The last Dart presentation target is
  retained across output reconfiguration so a topology change cannot move the
  framework clock backwards.
- **Phase 2 implemented and accepted by the user.** Every output now has a
  single typed in-flight state (`Scheduled` or `Submitted`) and one unique Ready
  slot. An unconsumed Ready frame cannot be replaced. The output pipeline is
  consulted independently at each timer tick, so an unavailable output stays
  dirty without blocking another output. Physical output pools contain exactly
  three buffers.
- **Phase 3 implemented and accepted by the user.** The selected
  output framebuffer is acquired before layer-tree diffing, its independent
  repair history participates in `FrameDamage`, and exact frame and buffer
  damage survive the engine-to-Rust handoff. Impeller loads persistent output
  contents for partial repair, clears only the repair region, and skips the GPU
  pass for known-empty damage. Pool histories advance only from frame damage.
- The first Phase 3 validation improved CPU use and frame rate but exposed
  black pixels outside intermittent repair regions together with short GPU and
  memory bursts. The cause was a mismatch in the Denial target contract: the
  compositor supplied a level-zero texture-backed FBO, while the engine exposed
  only the FBO and marked it render-target-only. A scene requiring root readback
  therefore forced Impeller to allocate a full-output intermediate, render only
  the damage into it, and copy the whole intermediate back over the persistent
  output. The engine now borrows the attached color texture and marks it
  render-target plus shader-read, keeping readback on the persistent output and
  removing that incorrect full-frame fallback. The user confirmed that this
  correction fixes the black-wallpaper damage failure and makes GPU behavior
  acceptable.
- **Mixed-refresh producer authorization corrected and accepted by the user.**
  Raster execution remains deliberately single-threaded, but
  producer capacity is no longer represented by one global busy bit. Each
  output can reserve exactly one free target at its own timer tick and enqueue
  that work independently onto Flutter's one raster task runner. This removes
  the 240/100 Hz phase collision that discarded an otherwise valid output tick,
  without permitting a second queued frame for the same output or replacing an
  unconsumed Ready frame. Unclaimed reservations expire after two intervals of
  their own output. On the validated 240/100 Hz system both UFO tests remain
  pinned to their output refresh, motion is visually smooth, and measured GPU
  use is approximately 12--13% at 55 W with 3% effective utilization.
- The narrow Phase 5 single-root Denial compositor fast path and Phase 6
  single-sample target contract were completed as dependencies of Phase 3.
  They remove the generic platform-view layer partitioning and implicit 4x MSAA
  resolve from negative per-output render views without changing ordinary
  Flutter embedder behavior.
- The Phase 3 implementation passes all 455 compositor tests, all 13 Rust
  Flutter-engine tests, all 289 Flutter flow tests, and its targeted embedder
  handoff tests. One unrelated stock Impeller root-transform/backdrop embedder
  test remains white in this host test harness; the Denial negative-view tests
  and the complete damage/diff suite pass. Runtime pixels, GPU load, cadence,
  power, and mixed-refresh acceptance remain owned by the user.
- Phase 4 remains unimplemented. The optional KMS damage-clip portion of Phase
  6 also remains unimplemented.

## Required final behavior

1. Every powered output retains its independent `OutputTimeline`, native-sized
   backing stores, exact scale, and independent KMS/Volition stream.
2. The one Dart scene has one monotonic animation timeline. Physical output
   timelines never compete to provide Flutter's global frame time.
3. At most one useful successor is submitted to KMS and one following frame is
   rendering or ready. Denial never rasterizes a frame merely to replace an
   unconsumed ready frame.
4. A rotating output pool contains three buffers: scanning, submitted, and
   rendering/ready. A fourth generation is not part of the steady-state
   architecture.
5. Denial repaints only the damage required to make the selected backing store
   current. The first frame and invalidated topology generations remain full
   repaints.
6. Impeller preserves undamaged pixels in Denial-owned persistent FBOs. It does
   not clear a complete output before a partial repaint.
7. Frame damage and buffer-repair damage remain distinct through the complete
   Flutter-to-Rust handoff.
8. The offscreen fallback copies only the region required to repair its paired
   scanout buffer.
9. No optimization reintroduces framebuffer upsampling, output-wide atlas
   rasterization, cross-output synchronization, or presentation-driven render
   ticks.

## What the engine renders today

The custom engine selection works as intended. A 240 Hz tick requests the
240 Hz native output, a 100 Hz tick requests the 100 Hz native output, and a
coincident tick supplies both render-view IDs in one raster transaction. With
two 2560x1440 outputs, continuous damage therefore authorizes approximately
240 plus 100 native single-output raster passes per second. It does not perform
340 double-wide 5120x1440 pixel rasterizations.

Dart still builds one logical desktop scene. The engine projects its shared
root into output-specific layer-tree tasks, and only selected tasks enter the
raster loop. Retaining one scene while rasterizing each output independently is
the required architecture.

## Confirmed regressions

### 1. Competing physical targets drive one Dart frame time

`FrameScheduler::step()` currently treats every pending Flutter baton as an
output-wide dirty event. Whichever dirty physical output next reaches a tick
can consume the baton. `render_authorized_outputs()` then derives Flutter's
frame target from that output's presentation target.

Presentation targets from different intervals are not a monotonic global
sequence. A representative ordering is:

```text
240 Hz target: 12.50 ms
100 Hz target: 20.00 ms
240 Hz target: 16.67 ms
```

Flutter consequently reports that frame time moved backwards and clamps it.
This concerns the one Dart/UI timeline, not the independently selected raster
targets.

### 2. Denial output tasks force full repaint

`Rasterizer::DrawToSurfaceUnsafe()` initializes every task with
`RasterDamagePolicy::kFullRepaint` and creates `FrameDamage` only when the task
is not a Denial output task:

```cpp
if (!denial_output_task &&
    frame->framebuffer_info().supports_partial_repaint) {
  ...
}
```

The engine already contains layer-tree diffing, dirty-external-texture
selection, existing-buffer repair, and an Impeller-specific partial-repaint
threshold. The physical-output path bypasses all of it.

### 3. Impeller clears the whole persistent FBO

`MakeRenderTargetFromBackingStoreImpeller()` wraps every borrowed output FBO
with:

```cpp
color0.load_action = impeller::LoadAction::kClear;
```

The current path therefore clears the complete output and then repaints the
complete output. Denial's rotating buffers are persistent and have explicit
repair history, so a partial pass must use a load action that preserves pixels
outside the repair region.

### 4. Exact damage is discarded at the compositor boundary

The Rust `present_view()` path currently forwards the generic layer paint
region as frame damage and supplies an empty buffer-damage list. The output
broker later constructs a full-output `ReadyOutputFrame.damage` regardless of
what the engine calculated.

Correct buffer-age tracking requires two distinct regions:

- **frame damage** is the new scene change and is accumulated into every other
  pool entry;
- **buffer damage** is the selected entry's existing repair plus current frame
  damage and is the region actually repainted.

Using buffer damage as frame damage is safe only by over-damaging and eventually
poisons the rotating histories. Dropping buffer damage makes partial rendering
incorrect. The custom Denial engine handoff must preserve both explicitly.

### 5. The producer can render a frame that is immediately discarded

`OutputBufferBroker::target_available()` checks for a free framebuffer but
does not reject an output whose ordinary ready frame has not been consumed.
`OutputScheduler::publish_ready()` explicitly replaces such a ready frame.

Under load this creates a self-amplifying failure:

```text
GPU completion is late
  -> ready frame cannot enter KMS yet
  -> another output tick authorizes a complete raster
  -> the newer result replaces the older unconsumed frame
  -> completed GPU work is discarded
  -> GPU completion falls further behind
```

Latest-value replacement is appropriate before raster authorization, where
dirty state can coalesce. It is not appropriate after an output frame has
consumed GPU time.

### 6. Four output buffers and two future KMS generations permit overproduction

`OUTPUT_POOL_LENGTH` is four and Volition permits two retained commit
generations per stream. The useful high-refresh ownership states are only:

```text
A: currently scanning
B: submitted to KMS for the next edge
C: rendering or ready for the following edge
```

While B is pending, C remains ready. After B flips, C can enter Volition for
the next absolute target. Rendering D before C is consumed wastes work and
memory.

For two direct 2560x1440 outputs, four color buffers per output occupy about
112.5 MiB, and one shared D24S8 attachment per output adds about 28.1 MiB.
Triple buffering reduces direct output-target storage from roughly 140.6 MiB
to 112.5 MiB. Offscreen mode also owns a second color pool, so the saving is
approximately twice as large there.

### 7. Offscreen fallback performs a full-output shader copy

When direct rendering into the scanout modifier is unavailable, Denial renders
into a linear DMA-BUF and `blit_to_scanout()` draws a full-screen triangle into
the paired scanout buffer. Scissoring is explicitly disabled. This path also
doubles color-buffer storage.

The current dual-monitor system uses direct targets, so this is not its primary
regression. It can be decisive on weaker hardware that selects
`offscreen_blit=true`.

### 8. Generic external-view composition adds avoidable CPU work

Synthetic Denial output tasks contain one Flutter root and no real Flutter
platform views, but they still pass through the generic external-view
`LayerBuilder` path. That path records and analyzes slices, creates a temporary
backing-store wrapper, constructs another display list, and dispatches it
through Impeller for each output frame.

This is not a second GPU rasterization: the first traversal records a display
list. It is nevertheless avoidable CPU allocation and traversal on a path that
may execute hundreds of times per second. It is a later optimization after
timing, ownership, and damage are correct.

### 9. Impeller's declared sample count conflicts with Denial's FBO contract

When implicit resolve is supported, the engine describes the borrowed output
FBO as four-sample and selects multisample-resolve store behavior. Denial's
target creation explicitly requires the actual imported FBO to be
single-sample.

The current visual path works, so the runtime cost of this descriptor mismatch
is not yet proven. It must be investigated after the confirmed regressions and
resolved to one explicit contract rather than changed speculatively.

### 10. One global producer gate couples independent output timelines

The first ownership implementation correctly made KMS/Volition availability
per-output, but `FrameScheduler` still consulted one global Flutter producer
state before authorizing any raster. A Requested, Rasterizing, or Preparing
transaction for one output therefore rejected a simultaneously due tick for
another output even when that output owned the third free target required by
the strict pool model.

Because `OutputTimeline::take_tick()` had already consumed the rejected tick,
the output then waited a complete refresh interval. On approximately 240 Hz
and 100 Hz timelines, their slowly moving phase repeatedly enters and leaves
this collision window. That matches the observed alternation between smooth,
near-target operation and slower, stuttering operation.

The producer contract is now per-output at authorization time and serial at
execution time:

```text
output tick -> reserve that output's sole producer slot -> raster task queue
                                                        -> one raster thread
```

Different outputs may each have one task queued. The same output may not queue
a successor until its reservation/rendering/ready ownership advances. This is
not parallel GPU rendering: it preserves one Flutter raster thread and one
linear Impeller command stream, avoiding duplicated GL contexts, glyph and
pipeline caches, texture ownership, and cross-context fences.

### Raster-cache clarification

The traditional Flutter flow raster cache is not an available optimization for
the active Impeller GLES backend: `GPUSurfaceGLImpeller::EnableRasterCache()`
returns false. The Denial-task cache exclusion looks suspicious but has no
runtime effect in this backend. This plan does not treat enabling the legacy
raster cache as a performance fix.

## Implementation sequence

### Phase 1: one monotonic Dart timeline

Keep every physical `OutputTimeline`. Add one explicit Dart scene timeline
derived from the fastest powered output. Only that timeline may satisfy a
framework `AwaitVSync` request and provide the global presentation timestamp.

At a Dart tick:

1. consume at most one pending framework baton;
2. provide a monotonically increasing target;
3. publish one latest Dart scene;
4. render physical outputs already authorized for that instant;
5. retain projected tasks for other outputs.

At a non-Dart output tick, raster the newest retained output task directly at
that output's native size. Do not wake Dart. Application commits continue to
dirty only intersecting outputs.

Required tests:

- mixed 240/100 Hz targets never move Dart time backwards;
- a continuous Dart animation produces at most the fastest output rate, not
  the sum of output rates;
- the 100 Hz output still receives 100 native raster authorizations;
- external-texture-only work never invokes Dart;
- topology changes select a new fastest timeline without stale timestamps.

User validation gate: mixed-refresh Flutter motion, both UFO tests, idle
cadence, and absence of frame-time clamping.

### Phase 2: strict output ownership and triple buffering

Make one output pipeline state machine authoritative for whether a raster may
begin. A due dirty tick may render only when the output has no unconsumed
following frame and owns a free render target.

Changes:

1. cap Volition to one scheduled/submitted generation per output stream;
2. keep one completed successor in the compositor-owned ready state;
3. never replace an ordinary ready frame;
4. leave newer commits coalesced in output dirty state until that ready frame
   advances;
5. reduce `OUTPUT_POOL_LENGTH` from four to three;
6. treat an unavailable output as dirty for its next tick; never opportunistically
   raster halfway through a period.

Required tests:

- scanning plus submitted plus ready consumes exactly three distinct entries;
- a fourth raster authorization is rejected without clearing dirty state;
- a late render fence cannot cause a completed frame to be replaced;
- one blocked output cannot block another output;
- screenshots retain their exact-frame semantics;
- page flips retire ownership but never create render authorization.

User validation gate: single-output 144 Hz cadence first, then dual-output
240/100 Hz cadence, GPU power, CPU use, and VRAM use.

### Phase 3: end-to-end per-output partial repaint

This phase is one coherent correctness change. Enabling only one of its pieces
can clear or preserve the wrong pixels.

Changes:

1. allow Denial output tasks to construct `FrameDamage`;
2. permit partial repaint for the Denial synthetic-output compositor path even
   though generic platform-view composition remains full repaint;
3. use the selected output task's previous tree, dirty texture IDs, and
   per-FBO existing damage;
4. preserve color outside the repair region in persistent Denial FBOs;
5. carry exact frame damage and buffer damage through the custom engine
   presentation handoff;
6. union only frame damage into other pool entries;
7. clear the selected entry's repair history only after successful raster;
8. publish real output damage instead of replacing it with the full frame;
9. invalidate every entry to full damage on size, projection, scale, transform,
   or topology-generation changes.

Required tests:

- first use of every pool entry is a full repaint;
- a small external texture update produces localized frame damage;
- selecting an older entry repaints current frame damage plus its accumulated
  repair history;
- repair damage does not spread into unrelated pool histories;
- empty scene damage preserves the selected buffer;
- backdrop/readback cases conservatively expand or force full damage;
- fractional-scale and transformed outputs map damage into exact native bounds;
- failed and abandoned raster transactions do not mark a buffer current.

User validation gate: text and effects remain correct while static portions of
each output stop consuming full-frame GPU work.

### Phase 4: damage-aware offscreen fallback

Use the selected pair's buffer damage for the linear-to-scanout copy. Skip the
copy for empty damage, use a bounded scissor strategy for partial damage, and
retain a full copy for invalidated or unsupported cases. Create the shader-copy
pipeline only when offscreen targets exist.

Required tests:

- partial repair updates the same coordinates in render and scanout buffers;
- rotating scanout pairs retain independent repair histories;
- empty damage emits no copy draw;
- full invalidation emits one full copy;
- Y orientation, transforms, and fractional scales remain unchanged.

User validation gate: the weaker fallback machine reaches its output refresh
rate without corruption, hangs, or disproportionate GPU memory use.

### Phase 5: Denial output compositor fast path

Add a narrow engine fast path for negative Denial render-view IDs containing
the single Flutter root and no real platform views. Preserve generic external
view behavior for ordinary Flutter embedders.

Potential work, accepted only when tests preserve identical output:

- bypass generic platform-view layer partitioning;
- avoid redundant display-list analysis and reconstruction;
- cache borrowed Impeller wrapper metadata by backing-store/FBO identity rather
  than pinning one framebuffer to a render view;
- retain one presentation callback and one GPU raster per selected output.

User validation gate: CPU use decreases without changing pixels, cadence,
damage, or backing-store ownership.

### Phase 6: resolve remaining measured GPU contracts

Investigate the single-sample FBO versus four-sample Impeller descriptor. If
the physical output path performs implicit MSAA work, make Denial's synthetic
targets explicitly single-sample unless image-quality evidence requires a
separate multisample target. Do not guess.

After exact output damage is available, add KMS `FB_DAMAGE_CLIPS` support where
the driver exposes it. This targets display/memory bandwidth rather than
Flutter raster time and must remain optional.

No uncertain optimization is retained merely because it changes a metric. It
must simplify the contract or show a repeatable improvement without visual or
cadence regression.

## Completion criteria

The performance stabilization is complete only when all of the following are
true and the user approves the result:

- single-output scaled and unscaled sessions retain native text quality;
- the established 144 Hz single-output test remains perfectly smooth;
- dual 240/100 Hz UFO tests reach their respective refresh rates without
  recurring stutter;
- cursor motion or unrelated Flutter UI motion is not required to stabilize
  application animation;
- Denial does not render or discard superseded ready frames;
- no Flutter frame-time clamping occurs in steady mixed-refresh operation;
- direct output pools contain three buffers per output;
- static output regions use partial repaint and preserve correct contents;
- offscreen fallback copies only required damage and remains correct;
- CPU, GPU power, and VRAM behavior are proportionate to the damaged pixels and
  active output refresh rates;
- the design has no fixed assumption that prevents 300 Hz operation;
- implementation and tests remain linear, explicit, and free of duplicate
  timing or ownership authorities.
