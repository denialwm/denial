# Target optimizations

## CPU profile: autonomous external-texture rendering

This document records the live CPU investigation performed on 2026-07-29.
It is intended to guide optimization work and to provide a baseline against
which later changes can be measured.

The primary finding is not that one visual effect is unusually expensive.
Denial is continuously executing a full-scene raster and driver-state path at
approximately 240 Hz. The Flutter raster thread is the largest consumer, but
the cost propagates through Mesa's GL and Gallium workers and into AMD command
submission.

The post-change trace found why the first region-aware implementation still
reached that full-scene path. Flutter emitted three logical damage rectangles,
but Denial's Rust history normalizer merged any touching rectangles by taking
their bounding box. That destroyed complex-region topology, filled the
undamaged gap, and stored a full-atlas repair region in each rotating buffer.
After that correction, a second profile showed that passing the now-exact
multi-rectangle region to Ganesh as a root path clip tripled raster CPU at the
same approximate cadence. The normalizer and the backend-specific correction
are both recorded below.

No source, process, graphical-session, or rendering configuration was changed
during the capture.

## Capture context

The profiled process was the installed optimized Denial release. Its engine
machine code was matched byte-for-byte with the unstripped local engine fork
before resolving samples. The installed Dart AOT image was regenerated from
the exact application kernel and matched by build ID before resolving Dart
samples.

The active render configuration was:

- Flutter atlas: 5120 by 1440 pixels.
- Render clock: 240.001 Hz.
- Rotating Flutter surface pool: five buffers.
- Outputs:
  - DP-4: 2560 by 1440 at 143.973 Hz.
  - DP-5: 2560 by 1440 at 240.001 Hz.
- GPU: AMD Radeon RX 9070 XT / Navi 48 using `amdgpu`.
- Mesa Gallium library: 26.1.5-arch3.1.

The original desktop workload was recovered from the compositor journal and a
narrow query of Chromium history after the first capture. Chromium was
maximized at `x=11, y=33`, with a 2538 by 1396 surface on DP-5, and its active
page was `Thebausffs - Twitch` (`https://www.twitch.tv/thebausffs`). Kitty
windows were visible on DP-4. The browser history also shows that frame-rate
limiting was being investigated immediately before the capture. UFO Test was
not the original 43.30% workload; it was used only as a later high-cadence
diagnostic.

A twelve-second `pidstat` capture measured 43.30% CPU in total. A separate
five-second hardware-counter capture measured 49.7% CPU. These percentages
use the Linux convention where 100% represents one logical CPU.

The hardware-counter window recorded:

- 2,487.34 ms of task clock over five seconds.
- 6.448 billion cycles.
- 9.388 billion retired instructions.
- 1.46 instructions per cycle.
- 1.749 billion branches.
- 40.2 million branch misses, or 2.30%.
- 1.023 billion cache references.
- 224.7 million cache misses as reported by the hardware event.

### Preserved raw captures

The two raw profiles are preserved under
[`profiling/2026-07-29-cpu-regression`](../profiling/2026-07-29-cpu-regression/):

- [`denial-cpu.perf.data`](../profiling/2026-07-29-cpu-regression/denial-cpu.perf.data)
  contains the cycle samples and DWARF call graphs.
- [`denial-instructions.perf.data`](../profiling/2026-07-29-cpu-regression/denial-instructions.perf.data)
  contains the retired-instruction samples.

Their sizes, SHA-256 digests and captured object build IDs are recorded beside
the files.

## CPU by thread

The `pidstat` averages are the authoritative CPU-time split. Cycle and retired
instruction samples were then used to locate the work within each active
thread.

| Thread | Captured TID | CPU | Share of Denial CPU | Primary repeated work |
| --- | ---: | ---: | ---: | --- |
| `io.flutter.rast` | 1048155 | 25.56% | 59.0% | Full layer traversal, GPU program-key construction, transforms, filters, glyphs, draw-op recording and flushing |
| `deniald:gdrv0` | 1048149 | 5.08% | 11.7% | Gallium framebuffer, sampler and vertex state; atomic resource references |
| `deniald:gl0` | 1048150 | 4.58% | 10.6% | GL framebuffer binds, object lookup locks, uniform validation and references |
| `deniald` main | 1048115 | 4.25% | 9.8% | Complete output-control state reconstruction, allocation and mode sorting |
| `deniald:cs0` | 1048136 | 1.92% | 4.4% | AMD command submission, buffer-object and fence dependencies, kernel `ioctl` work |
| `io.flutter.ui` | 1048154 | 1.75% | 4.0% | Layer attach/detach, Dart allocation, window snapshot decoding and paint bookkeeping |
| `denial-priority` | 1048125 | 0.08% | 0.2% | Negligible |
| Approximately 42 other threads | — | 0% | 0% | No measurable CPU in the capture |

The raster, GL, Gallium and command-submission threads together used 37.14
percentage points, or approximately 85.8% of all measured Denial CPU. Not all
of that work can be eliminated, but it identifies the render pipeline as the
dominant optimization target.

## Frame cadence

The raster profile contained 3,374 samples over 14.943 seconds. Of the 3,373
gaps between samples, 2,867 were between three and five milliseconds. The mean
gap was 4.430 ms.

The 240.001 Hz output period is 4.167 ms. The raster work is therefore
phase-locked to the fastest output rather than occurring as occasional UI
work. At the measured 25.56% raster CPU, the raster thread consumes roughly
1.065 ms of CPU per 240 Hz interval. Total Denial work is roughly 1.80 ms of
aggregate CPU per interval at the 43.30% capture average.

The scheduler only requests this autonomous path when application textures
have been marked as updated. The cadence, the high raster cost and the low Dart
UI cost strongly identify repeated external-texture frames. The capture could
not associate those updates with a particular Wayland surface because live
uprobes and tracefs were unavailable.

## Causal rendering path

The observed work follows this path:

```text
external-texture update at approximately 240 Hz
    -> Engine::ScheduleFrame(false)
    -> DrawLastLayerTrees()
    -> reuse the existing Dart layer tree
    -> pass is_reused_layer_tree as force_full_repaint
    -> discard the computed raster clip
    -> preroll with kGiantRect
    -> traverse and paint the complete Flutter scene
    -> submit GL framebuffer, sampler, uniform and vertex state
    -> Gallium resource reference and descriptor work
    -> AMD command submission and fence processing
```

The critical engine code is in
`engine/src/flutter/shell/common/rasterizer.cc`. A reused task selects its
in-flight tree as the previous tree and passes `is_reused_layer_tree` to
`DrawToSurfaceUnsafe` as the full-repaint argument.

In `engine/src/flutter/flow/compositor_context.cc`,
`CompositorContext::ScopedFrame::Raster` then executes:

```cpp
if (force_full_repaint) {
  clip_rect = std::nullopt;
  frame_damage->Reset();
}
```

Preroll subsequently receives `kGiantRect` when `clip_rect` is absent.

The behavior was introduced by Flutter fork commit
[`cf6d28175ad`](https://github.com/denialwm/flutter/commit/cf6d28175ad),
`Decouple autonomous damage from the raster clip`. It follows:

- [`ef8d243f38b`](https://github.com/denialwm/flutter/commit/ef8d243f38b),
  which preserved partial damage for reused layer trees.
- [`21460af54b5`](https://github.com/denialwm/flutter/commit/21460af54b5),
  which limited autonomous damage to marked texture IDs.

The later `cf6d28175ad` change retains useful output damage while explicitly
removing that damage from raster clipping. Consequently, a precise published
output-damage value does not prove that rasterization is partial.

The statement in
[`RENDER_AUDIT.md`](./RENDER_AUDIT.md#autonomous-external-texture-damage)
that a high-rate client does not turn every update into a full-atlas repaint
described the earlier `ef8d243f38b` behavior. It was stale relative to the
later full-repaint branch; that audit is updated alongside the region-aware
implementation recorded below.

## Instruction-level findings

### Flutter raster thread

Cycle samples within `io.flutter.rast` were divided approximately as follows:

- 70.8% Flutter engine and Skia.
- 15.7% Mesa/Gallium.
- 8.7% libc and allocator work.
- The remainder in libm, unresolved generated code and small libraries.

No individual raster instruction dominates. The cost is distributed across
blocks that execute repeatedly while traversing and drawing the full scene.

#### GPU program-key construction

`KeyBuilder::addBits`, starting at engine text offset `0x7e3720`, was the
largest direct engine symbol:

- `mov 0x14(%rdi), %ecx`: 31.68% of samples within the function.
- `mov %edx, %eax`: 33.73% of samples within the function.
- Variable shifts, masks, OR operations and a `TArray` append complete each
  packed key segment.

This is evidence of frequent GPU pipeline/program key generation, not slow
individual `mov` instructions.

#### Layer diff traversal

`ContainerLayer::DiffChildren` was another leading direct symbol. Its hottest
sample was `setb %r8b` at text offset `0xb13d67`, inside a comparison and
tree/map lookup loop. This represents repeated child lookup and layer-diff
traversal.

#### Glyph and matrix state

The hottest sample in `can_use_direct` landed on the function epilogue at
offset `0x943ce1`. The epilogue is not intrinsically expensive; sampling skid
at the return indicates that the glyph transform/direct-rendering eligibility
test is invoked very frequently.

`SkDevice::setGlobalCTM` sampled most heavily at offset `0x5ac592`, on a
`movups` used after SIMD matrix work. This indicates repeated current-transform
matrix changes throughout the draw.

#### Other repeated raster work

Other recurring symbols included:

- `FragmentProcessor::visitTextureEffects`.
- Fragment processor construction and processor-key finalization.
- Filter-result bounds analysis and rescaling.
- `SkBlurImageFilter::onFilterImage`.
- `GrGLOpsRenderPass::onBindPipeline`.
- Render-task interval collection and resource allocation.
- `SurfaceDrawContext::fillRectToRect`.
- Fill-rrect preparation.
- SkPaint-to-GrPaint conversion.
- Glyph-list drawing and text-blob key comparisons.
- Draw-op recording, concatenation and execution.
- Drawing-manager flushes.
- Display-list layer painting and clip-stack application.

Blur is present but is not the dominant instruction path.
`SkBlurImageFilter::onFilterImage` accounted for 0.42% of global direct cycle
samples, while `Compute2DBlurKernel` accounted for 0.23%. Disabling blur would
leave the continuous traversal, program-key, draw-op and driver-state work in
place.

Allocator churn is measurable but secondary. Direct `malloc` and `free`
samples on the raster thread accounted for approximately 1.01% and 0.68% of
global cycles respectively.

### Gallium driver thread

The installed Gallium library is stripped, so its hottest text offsets were
mapped against Mesa 26.1.5 source and local disassembly.

The main repeated operations in `deniald:gdrv0` were:

- Offset `0x8685f4`: `lock subl $1, (%rsi)` in
  `util_copy_framebuffer_state`, reached from `si_set_framebuffer_state`.
  This updates references to old and new color surfaces for framebuffer state.
- Offset `0xbe158e`: the branch following a locked reference decrement in
  `pipe_sampler_view_reference`, inside `si_set_sampler_views`. This performs
  sampler-slot descriptor, decompression and reference checks.
- Offset `0xb5a29e`: the branch following a locked decrement in
  `si_bind_vertex_elements`. This releases previous vertex-buffer state during
  vertex-element changes.

The locked atomic instructions are not independent root causes. They are
downstream evidence that the engine is repeatedly resubmitting framebuffer,
sampler and vertex state.

### Mesa GL worker

The main repeated operations in `deniald:gl0` were:

- Offset `0xf359f`: the branch following a locked decrement in Mesa's
  `bind_framebuffer` path. This path locks the shared framebuffer table, looks
  up the framebuffer object and binds draw/read state.
- Offset `0x3edf31`: another branch following a locked decrement around
  shared GL object/hash-table lookup.
- Offset `0x3ff303`: uniform location and linked-program validation.
- Offset `0x144717`: an atomic object/resource reference decrement.

The five rotating FBOs make framebuffer changes expected, but full-scene
repainting amplifies the amount of GL state and draw work associated with each
rotation. The rotating `SkSurface` cache removes wrapper recreation; it does
not remove the state stream generated by a complete repaint.

### AMD command-submission thread

`deniald:cs0` used 1.92% CPU, of which approximately 1.67 percentage points
were system CPU. User-space samples were in AMD winsys buffer-object,
dependency-mask and fence tracking. Retired-instruction samples also reached
libc's `ioctl`.

Kernel instruction symbols were unavailable because of host tracing and
kernel-pointer restrictions. Naming a specific kernel instruction would
therefore be unsupported. The useful optimization target is to reduce render
and command submissions rather than optimize the small user-space bookkeeping
instructions sampled around them.

### Main compositor thread

The main thread consumes 4.25% CPU. Its leading direct symbols included:

- `output_control_state`.
- Stable sorting and small-sort merge routines.
- `malloc` and `free`.
- The compositor event loop.
- Wayland surface commit and surface-tree traversal.
- `Space::refresh`.
- VDSO clock reads.

The two hottest instructions inside `output_control_state` were integer
division operations at binary offsets `0x4f38b2` and `0x4f38e4`. They occur in
DRM mode refresh-rate conversion.

The event loop currently calls:

```rust
output_control.publish(output_control_state(...)?);
```

unconditionally in
[`run_flutter_event_loop`](../compositor/src/bin/deniald.rs#L1967).
Before `publish` can determine that nothing changed,
`output_control_state` has already:

- Enumerated connected connectors and outputs.
- Scanned modes.
- Calculated refresh rates and logical geometry.
- Allocated vectors, maps and strings.
- Sorted advertised modes.
- Constructed the complete snapshot.

When external-texture rendering wakes the compositor at 240 Hz, unchanged
monitor topology is reconstructed up to 240 times per second.

### Flutter UI thread

The Flutter UI thread is a lower-priority target at 1.75% CPU. No Dart method
dominates.

The hottest resolved UI instruction was at app AOT offset `0x54a3ba` in
`ContainerLayer.detach`: `shr $0xc, %ecx` extracts the Dart class ID before
indirect child dispatch. This indicates repeated traversal of a child-layer
list rather than an expensive shift operation.

Another repeated path was `_iso_stub_AllocateClosureStub`, including the store
of the context field into a newly allocated closure. Other samples were spread
across:

- `ContainerLayer.updateSubtreeNeedsAddToScene`.
- Render-box default painting and hit testing.
- `PaintingContext`.
- `PipelineOwner.flushPaint`.
- Provider selector work.
- `DenialWireCodec.decodeWindows`.
- Parameterized-object and closure allocation.

This work may be optimized later by retaining layer subtrees and avoiding
redundant window-snapshot decoding, but it is not responsible for the current
CPU increase.

## Implemented correction

The structural correction was completed on 2026-08-02. Flutter fork commit
`c3ee9167475bb06d20abb689dc37f2c462909ba1`, `Preserve region damage through
rasterization`, replaces the reused-tree full-repaint shortcut with an
explicit damage policy and preserves regions through diffing, rasterization
and presentation. The Denial compositor separately makes output-control
publication event driven.

This is not a frame-rate cap, an effect toggle or a special case for the
profiled desktop. Autonomous external-texture frames can still run at the
fastest output cadence. The change reduces the amount of scene and driver work
performed for each frame to the pixels that changed plus the pixels required
to repair the selected rotating target.

### Region and target-buffer semantics

The engine now distinguishes three states throughout the damage pipeline:

- `std::nullopt`: target contents are unknown, so the conservative result is a
  full repaint.
- An empty `DlRegion`: target contents are known current and no pixels require
  repair.
- A non-empty `DlRegion`: exactly those rectangles require paint.

`DlRegion` construction from an empty rectangle vector was repaired so the
known-empty state is canonical and does not acquire historical or synthetic
damage.

`DiffContext::Damage` now retains two independent regions:

- `frame_damage` contains actual changes made by the current logical frame.
- `buffer_damage` is `frame_damage` union the repair history supplied for the
  selected FBO.

The five-buffer rotation is therefore handled without pretending that old
target damage is a new front-buffer change. Readback dependencies expand each
region independently to a fixed point, and clip alignment is applied to every
rectangle rather than to one atlas-wide bounding box.

The OpenGL embedder boundary preserves rectangle arrays in both directions.
Incoming existing-damage rectangles are checked for finite, ordered,
32-bit-representable bounds, rounded outward and stripped of empty entries.
The count is bounded at 4,096. Any malformed input becomes unknown damage and
therefore a full repaint. Outgoing `FlutterPresentInfo` retains every
`frame_damage` and `buffer_damage` rectangle. No Rust or Flutter embedder ABI
change was required.

### Explicit raster policy

`RasterDamagePolicy` now expresses the full-repaint decision directly. First
frames, abandoned/unknown targets, unsupported partial-repaint paths and
platform-view constraints remain conservative full repaints. Reusing the last
layer tree is no longer itself a full-repaint reason.

For autonomous frames, the existing dirty-texture ID set limits which
`TextureLayer` instances become dirty. In this first revision, the calculated
`buffer_damage` region drove raster clipping. Complex regions were installed
as a non-antialiased union-of-rectangles clip, so disjoint window or output
changes did not paint the undamaged space between them. Preroll used the
region bounds, the narrowest cull representation supported by the existing
layer API. The later normalizer-restart profile showed that this exact complex
root clip is itself uneconomical on Ganesh; the backend-aware planner recorded
below supersedes that part of the first revision.

When policy or backend economics choose a full repaint, only reported
`buffer_damage` is widened to the full target. `frame_damage` remains the true
logical change for output routing and the other rotating buffers' histories.

Region-aware per-subtree preroll rejection was deliberately not added in this
change. The post-fix profile must first show whether traversal inside the
region bounds remains significant enough to justify widening the layer API.

### Event-driven output-control publication

The compositor no longer constructs `output_control_state` on every event-loop
iteration. One `output_control_dirty` flag covers connector scans, topology
and mode changes, applied configuration, DPMS transitions and persistence
attempts. Repeated mutations coalesce at one loop-boundary publication gate.

`OutputControlPublisher::publish_if_dirty` does not invoke its state builder
on clean iterations, clears the flag only after a successful build and keeps
the existing equality comparison as a final serial guard. Direct apply
requests stage their fresh DRM connector scan until the boundary snapshot is
published; successful replies likewise use the boundary snapshot rather than
performing a second rebuild.

Steady 240 Hz rendering with unchanged output state therefore performs none
of the connector enumeration, refresh division, allocation or mode sorting
that dominated the baseline main-thread samples.

### Build and test evidence

The engine change passed:

- 20 `DisplayListRegion` tests.
- 278 `flow_unittests` tests.
- The complete 186-test embedder suite: 181 passed and five
  platform-dependent cases were skipped. Its GL damage cases cover full,
  empty, partial, unavailable, invalid and multi-rectangle existing damage.

The canonical builder regenerated and verified all three x86-64 engines from
the locked source and committed GN arguments:

| Mode | SHA-256 | GNU build ID |
| --- | --- | --- |
| release | `31b3b85e4e51cc6dc61342ea84e08f46de9f228660bb371c67f3bdeaa8327fcb` | `800914aeca069a1009642c0ae562d158b33eebbb` |
| debug | `23e73336292ab09f4e8a98d0d166dfab05e7576a71f2e3b43cd8143ce069472d` | `a2b0da93ebb93fed2cf24be71c1d908c9731b950` |
| profile | `5fdfdcdd2767c926f5a09394b63a1a39e38b3f8bf9687f486699f2db12052a47` | `9528fac5c64f8563669ee1a042641be21a916850` |

The prescribed Denial suite then passed 343 tests with two deliberate host
realtime probes ignored. The normal PC build regenerated the Dart bundle,
installed the checksum-matched release engine into it and produced optimized
`deniald` and `denialctl` binaries. All 315 Dart shell tests also passed.

## Post-restart live diagnosis

The user restarted into the rebuilt session on 2026-08-02. PID 76191 maps the
new `deniald` (GNU build ID
`0083bac7813ba4a0f7ae6ec2af465d77752194a3`) and the checksum-matched release
engine (GNU build ID `800914aeca069a1009642c0ae562d158b33eebbb`). The raw
post-restart captures and generated reports are preserved in:

- [`profiling/2026-08-02-region-damage`](../profiling/2026-08-02-region-damage/)
  for the 240 Hz UFO diagnostic.
- [`profiling/2026-08-02-region-damage-twitch`](../profiling/2026-08-02-region-damage-twitch/)
  for the later Twitch workload.

### 240 Hz UFO diagnostic

UFO Test kept the autonomous path close to the fastest output cadence. This
was deliberately treated as a diagnostic, not as the historical workload.
Its twelve-second `pidstat` average was 42.63%:

| Thread | Baseline Twitch | Post-restart UFO |
| --- | ---: | ---: |
| `io.flutter.rast` | 25.56% | 25.81% |
| `deniald:gdrv0` | 5.08% | 4.41% |
| `deniald:gl0` | 4.58% | 4.41% |
| `deniald` main | 4.25% | 4.25% |
| `deniald:cs0` | 1.92% | 1.58% |
| `io.flutter.ui` | 1.75% | 2.08% |
| Whole process | 43.30% | 42.63% |

The five-second UFO counter window retired 9.113 billion instructions and
6.405 billion cycles using 2,254.13 ms of task clock. The baseline windows
retired 9.388 billion instructions and 6.448 billion cycles using 2,487.34 ms.
Those scenes are different, so the small changes are not a controlled speedup.
The important result is that the dominant raster/driver path plainly remained
active after the region implementation.

The resolved raster symbols likewise remained full-scene work rather than one
isolated effect. Leading direct samples included:

- `DrawableSubRun::draw` and `PathSubRun::draw` for text.
- `GrDynamicAtlas::reset` and its lazy proxy callback.
- `ColorFilterLayer::Paint`, `ColorFilterLayer::Preroll` and
  `ColorFilterLayer::Diff`.
- `SkDevice::drawEdgeAAImageSet`.
- `GrProcessor::operator new`, fragment-processor coordinate-table rehashing,
  shader-cache unpacking and surface-context construction.
- `GrGLGpu::uploadColorToTex`, draw-op preparation and Ganesh flushing.

No individual instruction replaced the baseline cause. The same allocation,
layer traversal, text/image draw, program construction and submission blocks
were still being repeated.

### Twitch capture and cadence boundary

The user then closed UFO Test and opened a Twitch stream on DP-5. The resulting
twelve-second averages were:

| Thread | CPU | Share of Denial CPU |
| --- | ---: | ---: |
| `io.flutter.rast` | 9.92% | 58.9% |
| `deniald` main | 2.25% | 13.4% |
| `deniald:gdrv0` | 1.58% | 9.4% |
| `deniald:gl0` | 1.25% | 7.4% |
| `io.flutter.ui` | 1.08% | 6.4% |
| `deniald:cs0` | 0.58% | 3.4% |
| Whole process | 16.83% | 100% |

The five-second counter window measured 1,318.31 ms of task clock, 3.420
billion cycles and 4.268 billion retired instructions. These totals are much
lower than the original capture, but they are not evidence of a proportional
optimization. Non-stopping hardware execution breakpoints measured only
roughly 91--94 raster/present transactions per second in the saved windows,
and other short windows varied up to approximately 136 per second. The
original profile was phase-locked near 240 Hz. The original Chromium surface
was also maximized to 2538 by 1396 rather than necessarily being in browser
full-screen mode. A valid numeric before/after comparison still requires the
same page, geometry and delivered frame cadence.

The new Twitch cycle and retired-instruction profiles still assign 66.85% of
sampled user cycles and 69.11% of sampled retired instructions to
`io.flutter.rast`. Its direct samples remain distributed: `malloc` is 2.42%
of raster cycles and `free` 1.07%, followed by small blocks in
`GrProcessor::operator new`, `ColorFilterLayer::Paint`, glyph subrun drawing,
dynamic-atlas reset, fragment-processor construction, path drawing and Ganesh
draw preparation. The GL and Gallium workers still repeat the same object
lookup, locked reference, framebuffer, sampler and descriptor paths described
for the baseline. Lower frequency reduced how often that instruction stream
ran; it did not reveal a new single-instruction cause.

The main-thread result is structurally different. `output_control_state`, its
refresh-rate divisions and its mode sorts are absent from the new symbol
profile. The leading resolved work is now `Space::refresh`, Wayland surface
commit processing, popup enumeration, output-enter bookkeeping and clock
reads. This confirms that the P1 dirty gate removed steady-state output-state
reconstruction. The current 2.25% number itself remains cadence-dependent.

### Damage-path branch proof

Hardware execution breakpoints were placed on exact instructions in the
running stripped host and engine. They do not patch code or stop the session.
One five-second window counted 456 framebuffer acquisitions, 456
`populate_existing_damage` callbacks, 457 presents and 457 calls to
`CompositorContext::ScopedFrame::Raster`; the one-event edge difference is a
measurement-boundary effect. This rules out repeated acquisition, a missing
damage callback, and an abandoned-frame retry loop.

A second five-second window divided all 470 raster calls at the policy branch:

| Raster branch | Count | Share |
| --- | ---: | ---: |
| Valid `kUseDamageRegion` with a computed region | 470 | 100% |
| Missing optional damage region | 0 | 0% |
| Region already recognized as the full 5120 by 1440 atlas | 458 | 97.45% |
| Partial region accepted and installed as a canvas clip | 12 | 2.55% |

This established the live failure boundary: the new ABI, callback and policy
path was active, but the region arriving at the raster decision was already
the full atlas on almost every frame. Calling the first post-change result a
successful damage optimization would therefore have been incorrect.

### Frame-to-history root cause

The remaining discriminator was obtained without stopping Denial and without
reading `/proc/76191/mem`. Hardware execution breakpoints counted exact
instructions and captured the integer registers carrying slice lengths.

The selected-buffer history callback first showed:

| Existing-damage result | Count | Share |
| --- | ---: | ---: |
| Recognized selected framebuffer | 628 | 100% |
| Non-empty history | 616 | 98.09% |
| Exactly one rectangle | 616 | 98.09% |
| More than one rectangle | 0 | 0% |

In a simultaneous selected-history/raster window, 612 non-empty histories
matched 612 full-atlas raster branches, while 16 empty histories matched 16
partial branches. The full raster therefore followed the selected target's
stored repair history exactly; it was not a fallback caused by a missing
callback or policy value.

The outgoing side told the opposite story. One five-second trace observed
1,197 Flutter `frame_damage` inputs, every one containing exactly three raw
rectangles. A second simultaneous transition trace observed 222 frame inputs:
194 with three rectangles and 28 empty. Each `BufferBroker::mark_ready` call
unions the logical frame into `ready_damage` and the four non-selected slots,
so it produces five `DamageRegion::union` calls. The trace recorded:

- 975 union sources already normalized to one rectangle.
- 140 empty union sources.
- 403 executions of the `other is full atlas` branch.
- Zero executions of the ordinary partial-region insertion branch.

The 1,115 observed unions differ from `222 * 5` by exactly one five-union
frame at the measurement boundary. The expected empty count is exactly
`28 * 5 = 140`; the extra boundary frame was non-empty. Thus a three-rectangle
Flutter frame became one full-atlas Rust region before it entered rotating
buffer history.

The responsible code was `DamageRegion::insert`. Its old `touches` predicate
accepted any overlap or edge/corner contact, then replaced both rectangles
with their bounding box and restarted transitively. That operation is only
exact when the union is rectangular. For a complex or L-shaped region it
fills undamaged gaps; on the 5120 by 1440 multi-output atlas, the three
touching frame pieces collapsed to the atlas bounds. `DamageRegion::union`
then recognized the source as full and poisoned every older buffer's history.
The next `populate_existing_damage` callback correctly returned that poisoned
history, so the engine correctly—but unnecessarily—painted the full atlas.

The raw profiles, decoded register traces, instruction counts and build IDs
for this proof are preserved in
[`profiling/2026-08-02-region-damage-twitch`](../profiling/2026-08-02-region-damage-twitch/).

### Rust region-normalization correction

`DamageRegion` now coalesces two rectangles only when doing so introduces no
new pixels: containment, matching vertical spans with touching horizontal
intervals, or matching horizontal spans with touching vertical intervals.
Complex and L-shaped regions retain their component rectangles across frame,
ready and per-buffer history unions.

The fixed 32-rectangle callback storage remains bounded. When it is exhausted,
the region no longer collapses wholesale to one bounding box. Instead, the
compactor considers the existing rectangles plus the incoming rectangle and
merges only the pair whose bounding box adds the fewest undamaged pixels, with
deterministic area and index tie-breakers. This remains conservative—damage is
never lost—while avoiding a pathological atlas-wide expansion.

Regression tests cover the observed three-piece topology, propagation into a
buffer history, exact coalescing of true rectangular neighbors, repeated
identical unions, and capacity exhaustion without full-region collapse. The
complete compositor suite passes. The final optimized `deniald` has GNU build
ID `b26df5e08aacf6c3213067d06499d9f3716c2c7f` and SHA-256
`c2923179c4562850da5cd49911fa559bb79a55b047d466bb0f730c90874f28b5`.
The currently running PID 76191 predates this Rust correction; a
user-controlled session restart is required before its live CPU effect can be
measured.

## Exact-region restart: CPU regression and backend cause

The user restarted into the Rust normalizer correction with the same windows
open and the same full-screen Twitch stream on the 240 Hz monitor. The first
glance that CPU had increased was correct. Running PID 101983 used the corrected
`deniald` (GNU build ID `b26df5e08aacf6c3213067d06499d9f3716c2c7f`) and
the first region-aware engine (GNU build ID
`800914aeca069a1009642c0ae562d158b33eebbb`). Its raw profiles and all generated
per-thread reports are preserved in
[`profiling/2026-08-02-region-damage-normalizer-twitch`](../profiling/2026-08-02-region-damage-normalizer-twitch/).

The closest earlier Twitch window ran at roughly 91--94 raster transactions
per second. The corrected-normalizer window counted 495 acquire, existing
damage, present and raster callbacks in 5.001 seconds, or 98.97 complete
transactions per second. The cadence is not bit-for-bit identical, but a
roughly 5--9% cadence increase cannot account for the measured CPU increase:

| Thread | Earlier Twitch CPU | Corrected normalizer CPU | Multiplier |
| --- | ---: | ---: | ---: |
| `io.flutter.rast` | 9.92% | 30.83% | 3.11x |
| `deniald:gl0` | 1.25% | 6.58% | 5.26x |
| `deniald:gdrv0` | 1.58% | 6.42% | 4.06x |
| `deniald` main | 2.25% | 4.83% | 2.15x |
| `deniald:cs0` | 0.58% | 1.92% | 3.31x |
| `io.flutter.ui` | 1.08% | 1.83% | 1.69x |
| Whole process | 16.83% | 52.42% | 3.11x |

The five-second hardware-counter window independently measured 2,805.97 ms of
task clock, 8.563 billion cycles and 11.521 billion retired instructions. The
earlier Twitch window measured 1,318.31 ms, 3.420 billion cycles and 4.268
billion instructions. Thus this is an execution-cost regression, not merely a
percentage-display artifact.

### Current CPU and exact sampled instructions by thread

`pidstat` supplies CPU time. The cycle and instruction columns below are each
the thread's share of all sampled Denial user events. Percentages attached to
an instruction or address are relative to that individual thread.

| Thread | CPU | Share of process CPU | User cycles | User instructions | Hottest exact sampled work |
| --- | ---: | ---: | ---: | ---: | --- |
| `io.flutter.rast` | 30.83% | 58.8% | 66.01% | 64.39% | `malloc`; then TextBlob key comparison at engine text offset `0x944c42` |
| `deniald:gl0` | 6.58% | 12.6% | 13.36% | 15.35% | Mesa offset `0x3edf31`, shared GL object/hash lookup and reference branch |
| `deniald:gdrv0` | 6.42% | 12.2% | 13.16% | 16.53% | Mesa offset `0x8685f4`, a locked framebuffer-surface reference decrement |
| `deniald` main | 4.83% | 9.2% | 4.23% | 2.22% | VDSO time read; in Denial/Smithay, presentation feedback and `MultiCache::get` |
| `deniald:cs0` | 1.92% | 3.7% | 0.42% | 0.20% | Mesa offset `0xc0c503`, AMD winsys queue, fence and buffer bookkeeping |
| `io.flutter.ui` | 1.83% | 3.5% | 2.81% | 1.30% | Distributed stripped Dart AOT blocks; `malloc` is the leading named retired-instruction site |

On the raster thread, the single largest direct cycle address was inside
`malloc` at runtime IP `0x7fd207abe6ef`: 1.21% of raster cycles. The largest
engine instruction was `cmp (%rsi), %eax` in
`sktext::gpu::TextBlob::Key::operator==` at engine text offset `0x944c42`:
0.70% of raster cycles and 0.96% of raster instructions. It held 57.26% of the
cycle samples within that comparison function. `can_use_direct`,
`KeyBuilder::addBits`, `GrGLOpsRenderPass::onBindBuffers`,
`OpsTask::onExecute`, program lookup, transform changes and display-list
dispatch followed. This is still a wide repeated draw stream; there is no one
expensive visual effect or arithmetic instruction.

Comparing weighted sample rates over the two approximately 15-second Twitch
profiles shows where the extra repetitions accumulated:

| Raster work | Cycle-rate multiplier | Instruction-rate multiplier |
| --- | ---: | ---: |
| `malloc` | 2.38x | 4.93x |
| `free` | 3.57x | 3.26x |
| TextBlob key equality | 6.17x | 5.94x |
| `can_use_direct` glyph eligibility | 6.41x | 2.47x |
| `KeyBuilder::addBits` | 2.74x | 2.28x |
| Ganesh draw-op insertion | 2.69x | 2.40x |
| `GrGLOpsRenderPass::onBindPipeline` | 3.18x | 8.50x |

The functions specific to complex clipping grew even faster. Sampled cycle
rate rose 12.60x in `ClipStack::clip`, 5.21x in `ClipStack::apply`, 13.84x in
`SkPath::Iter::next` and 10.67x in the GL program cache. Ganesh render-task
recording rose 4.41x, while `OpsTask::onExecute` retired instructions at
11.14x the earlier rate. These multipliers connect the root clip to the
otherwise distributed allocator, text, program, pipeline and draw-op costs.

The GL worker's most repeated address was Mesa `0x3edf31`, at 5.65% of its
cycles and 5.64% of its retired instructions. Local disassembly and the Mesa
26.1.5 source place it in shared object/hash lookup and reference handling.
Offset `0xf359f`, the branch following the locked reference operation in
`bind_framebuffer`, accounted for 2.51% of cycles and 3.93% of instructions.

The Gallium worker's instruction leader was `0x8685f4` at 3.79% of its
instructions and 2.56% of its cycles: `lock subl $1, (%rsi)` in framebuffer
surface-state copying. The cycle leader, `0xbc679e`, used 2.61%. Offsets
`0xb5a29e` and `0xbe158e` were the existing vertex-element and sampler-view
reference branches. The state operations are repeated consequences of the
larger Ganesh draw stream, not independent locks that should be patched out of
Mesa.

The command-submission thread's `0xc0c503` represented 8.76% of its cycles and
7.24% of its instructions; `0xc0ca0b` and `0xc0c519` followed. These are AMD
winsys queue, fence, dependency and buffer-object paths. They are locally hot
because `cs0` is a small thread; it contributed only 0.42% of all sampled user
cycles. Kernel addresses remain unresolved, so no unsupported kernel
instruction name is assigned to them.

The main thread no longer contains the old output-control reconstruction. Its
hottest named cycle sites were Wayland presentation-feedback send (1.10% of
main cycles), `MultiCache::get` (1.07%), popup enumeration and `Space::refresh`.
`MultiCache::get` led named retired instructions at 1.46%. The VDSO clock site
at offset `0xbe0` was the absolute leader. The UI thread was only 1.83% CPU;
its stripped AOT image spreads samples across many code addresses, with no AOT
address above 1.79% of UI cycles and named `malloc` at 1.26% of UI retired
instructions. It is neither the origin nor the useful first target for this
regression.

### Proof that exact region normalization worked

The corrected Rust normalizer did not collapse damage back to the atlas and
did not itself consume the added CPU:

- A five-second branch trace observed 408 raster calls, all 408 with a valid
  region and all 408 taking the partial-region path. Zero took the known-full
  branch.
- A register trace observed 426 logical frame inputs: 399 contained exactly
  four rectangles and 27 were empty.
- Those frames produced exactly 2,130 history unions, or five unions per
  frame. Their source regions were four rectangles 1,995 times and empty 135
  times, exactly `399 * 5` and `27 * 5`.
- The bounded capacity compactor was not needed, and direct samples in
  `DamageRegion::insert` accounted for only about 0.15% of raster cycles.

Therefore the four-rectangle topology survived the callback, buffer history,
engine policy and raster decision. The CPU increase began after the engine
accepted that valid complex region.

### Ganesh complex root-clip mechanism

The first region-aware engine represented a complex `DlRegion` as a
non-antialiased union path and installed it as the canvas's root clip. On
Ganesh, a non-rectangular region does not remain a set of independent hardware
scissors. It enters the Ganesh clip stack as a path.

Every draw then calls the clip application machinery. `ClipStack::apply`
classifies the path against the draw, attempts scissor/window-rectangle,
analytic, atlas, stencil or software-mask representations, attaches clip state
and affects whether draw ops can combine. Caching a stencil mask can avoid
rerasterizing the same mask, but it does not remove this per-draw analysis,
state attachment or batching boundary. Replacing `clipPath` with Skia's
`clipRegion` is not a solution: Ganesh converts a non-rectangular `SkRegion`
boundary to a path in its device implementation.

This explains the entire measured shape: clip/path functions rose first, and
each layer draw then repeated more allocation, glyph-key comparisons,
program-key construction, pipeline binding, draw-op recording, GL object
lookups, Gallium state references and command submission. The root cause is
not blur and is not the four cheap Rust rectangle insertions.

### Backend-aware raster planner

Flutter fork commit `fc290f44fbcf39f272f270fd93c5517aed6cccd0`, `Plan
raster damage for backend cost`, implements the structural correction. A
testable `RasterDamagePlan` now takes exact damage, target size, explicit
damage policy and raster backend, then returns both the physical repaint
region and the conservative `buffer_damage` that must be reported.

The policy is:

- Empty and single-rectangle damage remain exact on every backend.
- Ganesh converts complex damage to its bounding rectangle, which remains a
  hardware-scissor clip. If that rectangle covers the target, Ganesh performs
  a normal full repaint without a complex root clip.
- Skia software retains the exact complex region because it does not pay the
  Ganesh GPU clip-stack cost.
- Impeller retains exact complex damage when it passes its existing 70% dirty
  area economy rule; otherwise it performs a full repaint.
- Exact logical `frame_damage` remains unchanged for output routing and other
  rotating buffers. Only `buffer_damage` is widened to the region the selected
  physical plan may actually modify.

This is backend cost planning rather than a Twitch special case, effect
toggle, frame cap or unconditional return to full-scene rendering. It keeps
partial repaint where the backend can execute it cheaply and avoids a
representation whose fixed per-draw cost exceeds the fragments it saves.

Nine focused planner tests cover unknown, explicit-full, empty, simple,
Ganesh bounding/full, software exact and Impeller exact/economic cases. The
complete flow suite passed 287 of 287 tests. The canonical source builder
verified all three pinned engines under cache key
`7e20831dbe5ef8f24894c033be222d3ef05cb5788476926c4f5a2d45c264ec40`:

| Mode | SHA-256 | GNU build ID |
| --- | --- | --- |
| release | `9d34792e4e91daa63c86415afd2b8c6c532c657ee65c0f0b666a333f7cd27966` | `5565733b03aacce4356cadbfea45f86883e77105` |
| debug | `f17312c019909d01777fbb1e54bfcf50124375d06ac4718d60794e7113a98622` | `e53c60ada6e4fdcb7852a2d6f4280715930d8980` |
| profile | `96ba5c0a74bc54e54cc0c6a2d88d5f9d66ce14da7219d5693155b2bc9c8db6e5` | `ac1713a20576f82c16a7b9f4930b2cececbc09f9` |

The PC build installed the checksum-matched release engine into the bundle and
rebuilt optimized `deniald` and `denialctl`. The repository test command passed
343 tests with two deliberate host realtime probes ignored. The new resident
engine still requires a user-controlled graphical-session restart before a
live post-planner CPU measurement can be made.

## Optimization priorities

### P0: Backend-aware autonomous rasterization — planner built

The implementation keeps logical frame damage separate from selected-buffer
repair, preserves complex disjoint topology on both sides of the ABI and uses
explicit conservative full-repaint reasons. Physical repaint representation
is now selected per backend: exact where economical, a bounding scissor for a
complex Ganesh region, or full target when that scissor would already cover
the target. It is a general region and backend-cost correction, not a visual
effect toggle, client special case or frame cap.

The 97.45% full-atlas branch rate belongs to the binary before the Rust
normalizer correction. The later 100% partial-branch trace belongs to the
exact-region engine before the Ganesh planner. Both remain honest historical
measurements, not evidence about the final newly built engine.

Success remains a coordinated fall in `io.flutter.rast`, `deniald:gl0`,
`deniald:gdrv0` and `deniald:cs0` at the same client frame cadence.

### P1: Make output-control snapshots event driven — implemented

The dirty flag and single publication gate now cover connector discovery,
mode and topology changes, applied configuration, output power and
persistence. The publisher equality check remains the final guard rather than
the mechanism used to avoid state construction.

Expected profile change: integer divisions in `output_control_state`, stable
sorts, and associated main-thread allocation should disappear during steady
rendering with unchanged outputs.

The post-restart profile observes exactly that structural change:
`output_control_state` and its child divisions and sorts no longer appear.

### P2: Re-evaluate GL and Gallium state after partial rasterization

Do not begin by patching Mesa's atomic reference operations. They are generated
by repeated state submissions upstream.

After P0, profile again and determine whether Denial/Flutter still submits
redundant:

- Framebuffer binds when the selected FBO has not changed.
- Sampler-view updates with identical textures and descriptors.
- Vertex-element and vertex-buffer bindings.
- Uniform updates with unchanged values.
- Pipeline-key construction for reusable programs.

Only state that remains redundant after damage-aware painting should be
optimized directly.

### P3: Identify the 240 Hz external-texture producer

The scheduler is correctly gated on marked application textures, so it should
not be capped blindly. A client that genuinely submits 240 frames per second
may require that cadence.

Add or enable tracing that maps:

- Dirty external texture ID.
- Wayland surface and client.
- Buffer commit sequence.
- Scheduled autonomous frame.
- Whether the update produced visible damage.

If Denial is expected to be visually idle, this trace will distinguish a real
240 Hz client from bookkeeping-only or duplicate texture notifications.

### P4: Reduce Dart layer and snapshot churn

Only after the render and main-thread targets have been addressed:

- Avoid replacing or detaching unchanged layer subtrees.
- Reuse decoded window snapshot structures where possible.
- Avoid closure allocation in per-frame traversal paths.
- Confirm that provider selectors do not recompute for unchanged window data.

The maximum benefit is much smaller than P0 because the UI thread represented
only 4.0% of baseline Denial CPU and remains near one percentage point of one
logical CPU in the post-restart Twitch capture.

## Non-conclusions

- Blur is not the primary cause.
- The corrected Rust region normalizer is not the new CPU cause.
- An exact multi-rectangle root clip is not automatically cheaper on Ganesh.
- Mesa's atomic reference instructions are not independent root causes.
- Real-time scheduling changes priority and latency; they do not by themselves
  create the measured retired instructions.
- Advertising the Wayland viewporter protocol did not appear in any hot path.
- The profile does not yet identify which Wayland client owns the 240 Hz
  external texture.
- Exact kernel instructions within AMD command submission were not observable
  under the host's tracing restrictions.
- The lower Twitch aggregate after restart is not a speedup claim because its
  measured presentation cadence was substantially below the baseline cadence.
- Region support being active is not evidence of effective partial repaint;
  the pre-normalizer-correction branch count showed a full buffer region on
  97.45% of sampled Twitch frames, and the transition trace identifies the
  exact Rust coalescing operation that produced it.
