# Layered composition

Design contract for agents. Accepted 2026-10-16. Phases 1 and 3 and part of
phase 2 are implemented in the Flutter fork and always on; the phase table
records status.

## Problem

Flutter partial repaint is per output buffer. Any damage, such as an animated
wallpaper texture or a client buffer under glass, re-rasterizes everything
intersecting it through Impeller, whose per-frame CPU is O(scene)
(`docs/benchmarks`, render bench 2026-10-14). Shell content that did not change
is redrawn every frame.

## Model

One bundle, one engine, one widget tree. The layer tree marks **cuts** in
paint order. What lies between two consecutive cuts is a **slice**. The engine
turns a frame into an ordered entry list per output view and composes it.

Entry kinds:

- **Slice**: engine-rendered content (shadows, frames, text, icons). A
  tight-bounds texture, re-rendered by Impeller only when its display list
  changed.
- **External texture**: client buffer, wallpaper video, cursor. Never
  rasterized into a slice. Placed by the cut's clip/transform/opacity
  mutators.
- **Material**: window glass (`DlWindowSurfaceFilter`) or a backdrop filter.
  Evaluated against the composite so far, inside its bounds.

Rules:

- Glass is a cut, never an effect inside a slice. Glass over glass is two
  material cuts in order.
- Opacity, transforms, clips and saveLayers inside a slice behave as today.
- Slice identity = position in the per-frame entry list; a slice is reused
  when its bounds and display list are equal to the previous frame's.
- Fixed "four layers" are rejected: a windows layer cannot host per-window
  glass and re-renders on any window change.

## Seam

Flutter's embedder compositor protocol inside the fork, not a new deniald
protocol. Cuts are platform views registered during preroll
(`ExternalViewEmbedder::DenialRegisterCut`); the layers between them are the
existing `EmbedderExternalView` slices. Composition runs in
`EmbedderExternalViewEmbedder::SubmitDenialLayered` on Impeller into the
single Denial output target, so deniald keeps its one-layer `present_view`
path and all existing window, glass and texture shaders stay the visual
oracle.

No Dart change: `WindowSurfaceLayer`, `BackdropFilterLayer` and
`TextureLayer` become cuts in the fork on Denial output views. Dart
primitives (`WindowPlane`, `ShellBackdropBlur`, `Texture`) are unchanged.

## Fork implementation

Always on for Denial output views (negative view ids), with no switch
(2026-10-16). Other views keep the upstream path.

The embedder chooses a mode for every output frame
(`ExternalViewEmbedder::DenialBeginOutputFrame`):

- **Direct**: a new layer tree paints inline into the root slice, clipped to
  the frame damage, exactly as the upstream path does. Animated frames change
  most slices, so layering them costs more than it saves.
- **Layered build**: after four consecutive texture-only frames of one tree
  (the tree is unchanged and only external textures are dirty), cuts are
  registered, every slice is recorded in full, changed slices are
  re-rendered, and the entry list (slices and cuts with their mutators) is
  retained for that tree.
- **Recompose**: later texture-only frames of that tree skip Preroll and
  Paint. The rasterizer computes only the frame damage from the retained
  diff metadata; the embedder composes the retained entries inside it.

Any direct frame drops the retained entries, so they always describe the
target's current pixels. A tree whose build registers no cuts stays direct
until it changes.

- `flow/embedded_views.h`: `DenialCutEntry` (window surface, material
  begin/end, texture) and the embedder hooks.
- `flow/layers/{window_surface,backdrop_filter,texture}_layer.cc`: register
  cuts in `Preroll`; `Paint` switches the slice canvas instead of drawing.
- `shell/platform/embedder/embedder_external_view_embedder.cc`: renders each
  slice to a retained `DenialSlice` texture when its display list changed,
  then draws entries in order with `PaintWindow`, `DrawImage` or a backdrop
  `SaveLayer`, and presents one backing store.
- A slice renders as the output's root pass would draw it, with the output
  target's sample count (single-sample on Denial outputs), so layered and
  direct frames match. Its storage is only the color texture (4 bytes per
  pixel); depth/stencil, and MSAA color where the output uses it, are created
  for each render and released with it, as the root pass's are.
- A slice renders into the top-left corner of its slot's storage while the
  slice fits in at most twice its area, since each re-render clears the whole
  storage. Otherwise the slot takes the smallest such storage that another
  slice released earlier in the same build, and only then allocates exactly
  the slice's extent, rounded up to 64 pixels. Storage that no slice of the
  build took, and the storage of slots beyond the build's last slice, is
  freed when the build ends, so retained storage follows the current scene.
- Every layered frame keeps frame damage diffing. The composition clips to
  the buffer damage, clears it, and loads the target outside it, as the
  direct path's partial repaint does.
- A slice is blitted by the disjoint rects of its paint region (the union of
  its ops' bounds) when there are at most 32 and they cover at most 75 % of
  its bounds, otherwise by its bounds. Overlapping rects are never used: they
  would blend twice. Content that paints only around a window, such as its
  shadow, must record bounds that say so (`DesktopWindowShadowPainter`
  paints four disjoint bands, not one clipped draw spanning the window).
- Direct frames record the root slice without an rtree and present the whole
  target as its paint region; only layered builds need slice regions.
- Window-surface and backdrop cuts carry their layer's backdrop snapshot
  cache state; its token is read when composing, so still glass reuses its
  cached snapshot and a recomposition sees that frame's invalidations.
- `flow/compositor_context.*`: `RasterPaintScope` lets a layered build paint
  the tree unclipped and a recomposition compute damage only.
- `shell/common/rasterizer.cc`: asks the embedder for the mode and routes
  recompositions to `ExternalViewEmbedder::DenialRecompose`.

## Telemetry

With `DENIAL_RENDER_AUDIT=1` as well, the engine logs one line per output
view and second, beside deniald's "Flutter per-output render audit":

```text
Denial layered composition audit view=-1 interval_ms=… direct_frames=…
  layered_frames=… recomposed_frames=… single_slice_frames=… failed_frames=…
  composed_pixels=… window_cuts=… material_cuts=…
  texture_cuts=… max_cuts=… slices=… max_slices=… slices_reused=…
  slices_rendered=… rendered_new=… rendered_bounds=… rendered_content=…
  rendered_pixels=… rendered_slice_pixels=… slice_allocations=…
  slice_pool_reuses=… retained_slices=… retained_slice_pixels=…
  slice_render_total_us=… compose_total_us=… compose_max_us=… recompose_total_us=… recompose_max_us=…
```

`layered_frames` are builds, `single_slice_frames` builds without cuts, and
`composed_pixels` the buffer damage that layered frames composed.

Cuts are counted by kind; material ends are not counted. A re-rendered slice
records one reason: `new` (no retained texture), `bounds` (bounds changed) or
`content` (display list not equal). `rendered_pixels` is the storage area
cleared and drawn; `rendered_slice_pixels` is the slices' own rounded extent,
so the difference is the cost of storage kept larger than the slice.
`slice_pool_reuses` counts storage a slot took over from another slice in the
same build instead of allocating. Times are
raster-thread CPU before the present callback, not GPU time. `tools/denial-benchmark --capture-audit` summarizes
these lines per phase.

## Phases

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Cuts for glass, backdrop and textures; slices retained by display-list equality; composition on Impeller; audit counters; on by default (no switch) | implemented; renders correctly on the Pad 4 (2026-10-16) |
| 2 | Composition clipped to frame damage and backdrop snapshot cache tokens: implemented. Slice damage (re-render only a changed slice's changed region): planned | partial |
| 3 | Texture-only frames: recompose the retained entry list without Preroll or Paint; animated frames stay direct | implemented (2026-10-16) |
| 4 | Occlusion culling, move-only slice reuse, KMS overlay planes (`docs/direct_scanout.md`) | planned |

Test device: OnePlus Pad 4 (`/mnt/development/onepluspad4`). Benchmarks:
`tools/denial-benchmark`, records in `docs/benchmarks/desktop`.

## Known costs

- Animated (direct) frames still record every layer's display list; only
  texture-only frames skip Preroll and Paint.
- GPU memory rises: slices are allocated at content bounds even where a client
  texture covers them. Occlusion culling reduces it. CPU is the priority.
- Materials over an animated texture re-evaluate every frame until phase 2.
- Moving content defeats exact-bounds retention: on the Pad 4 (2026-10-16,
  1 window and 2 material cuts, 4 slices) motion re-rendered nearly every
  slice for changed bounds or content, reallocated 40–52 slice textures per
  second, and re-rendered about 1.8× the output's pixels per frame. When
  still, 100 % of slices were reused at about 0.5 ms composition CPU per
  frame.
- On texture-only frames about 40 % of raster-thread CPU is the driver
  flush and submit behind the present fence (`EGLFence::create`), not
  composition.

## Results (Pad 4, 2026-10-16)

Scenario `frame-delivery-off02` (Firefox, Settings and the native render
workload; CPU clamped to 2.112 GHz, GPU to 646 MHz): deniald process CPU in
% of one core from the runner summary, two runs each. "Before" is the
2026-10-15 baseline.

| Phase | Before | Layered (12) | + SHM release (13–14) | + labels (16) | + deck (18) | + boundaries (20) | + polling (21) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Overview, 500 ms toggles | 16.2 / 15.5 | 15.0 / 14.3 | 13.8 / 12.5 | 13.8 / 12.5 | 12.9 / 12.4 | 13.3 / 12.6 | 13.2 / 12.8 |
| Overview, 80 ms toggles | 37.8 / 35.3 | 31.8 / 28.0 | 27.1 / 26.8 | 26.1 / 26.2 | 25.1 / 24.8 | 25.2 / 24.8 | 25.5 / 24.9 |
| Render client, texture only | 8.8 / 8.7 | 6.5 / 6.4 | 6.5 / 6.5 | 6.6 / 6.2 | 5.8 / 5.9 | 6.7 / 6.5 | 6.5 / 6.4 |
| Render client + overview | 23.3 / 23.8 | 21.0 / 21.6 | 21.4 / 21.5 | 21.6 / 22.6 | 21.5 / 21.9 | 20.1 / 20.2 | 20.2 / 20.3 |

With the deck change the render client also kept about 113 instead of 110 fps
under the overview, and the 80 ms phase presented about 3 % more frames. The
texture-only phase draws no deck or window motion; its lower value in 18 is run
noise (16, 17, 19 and 20 measured 6.2–6.7).

Outside the fork, these changes count:

- deniald releases an SHM buffer as soon as it has copied it. GTK 3 draws
  into a released buffer again; while deniald held it, Firefox allocated and
  mapped a new 32 MB pool per repaint (51 pools to 2 in the same trace).
- The CPU-hint worker reuses a process's frame-thread list for a second
  instead of rescanning `/proc/PID/task` on every focus change.
- A text op that draws one glyph without a mask or image filter keeps its
  display list group-opacity compatible (fork), so the overview's workspace
  labels fade with `Opacity` instead of rebuilding their paragraphs every
  frame. Filtered text keeps its saveLayer: Impeller filter contents ignore
  an inherited opacity.
- The overview deck's zoom drives layout and paint through listenable render
  objects (placement, faded decorations, a `FadeTransition` label) instead of
  an `AnimatedBuilder` that rebuilt every card's semantics, gestures,
  decoration tween and text on each frame. The UI thread fell by about
  1.1 points with 80 ms toggles.
- The deck paints behind its own repaint boundary, and its labels are laid
  out without a width bound when they fit, so a zoom frame re-records neither
  the scene root nor the label paragraphs. A retained window preview without
  a scene clip applies its visual transform as a composited `TransformLayer`
  property, so moving or scaling it repaints nothing. With the render client
  under the overview the UI thread fell from about 7.0 to 6.3 points.
- calloop polls through the in-tree `compositor/polling` crate instead of
  crates.io `polling`, which re-armed a timerfd and a one-shot notifier around
  every wait. A wait is now one `epoll_pwait2`. With 80 ms toggles the main
  thread's system calls fell from about 6400 to 3200 per second; process
  totals stayed within run noise. What remains per wake is `wayland-backend`'s
  nested epoll poll and fml's per-task `timerfd_settime` (about 2 % of the
  main and UI threads each).

Not adopted: `GALLIUM_THREAD=0` (the raster thread then spends more than
the driver thread saved once the overview settles) and `FD_MESA_DEBUG=sysmem`
(about 2 points less with 80 ms toggles, but 6–12 % fewer frames presented
and the render client fell from about 110 to 106 fps; the clients inherited
the variable, so the run does not isolate deniald).

Firefox's GTK 3 toplevel repaints its whole 32 MB SHM surface in software on
every keyboard leave or enter, about 93 % of it under its opaque content
subsurface, and deniald copies it. The overview takes keyboard focus on every
toggle, so deniald misses vblanks while animating: 505 doubled frame intervals
in the 500 ms phase and 258 with 80 ms toggles (candidate 21).

With Chromium 153 (native Wayland, "use system title bar and borders") in
Firefox's place, Chromium repaints on focus changes on the GPU into
explicitly synchronized UBWC dmabufs. Same session (candidate 21), Firefox
then Chromium, frames in parentheses:

| Phase | Firefox | Chromium |
| --- | --- | --- |
| Overview, 500 ms toggles | 13.2 / 12.8 (1760 / 1641) | 15.5 / 14.3 (2204 / 2210) |
| Overview, 80 ms toggles | 25.5 / 24.9 (2603 / 2711) | 20.4 / 20.4 (2865 / 2867) |
| Render client, texture only | 6.5 / 6.4 | 6.3 / 6.0 |
| Render client + overview | 20.2 / 20.3 | 19.5 / 20.1 |

With Chromium the 80 ms phase holds 120 Hz and the deniald main thread falls
from about 5.9 to 1.7 points; doubled frame intervals drop to 36 and 4. The
500 ms phase costs more in total because it presents 30 % more frames.
With its own frame, Chromium draws a client-side shadow margin into an ARGB
buffer and clears its opaque region, so deniald composes the whole window as
translucent: the 80 ms phase then needed 8.8 instead of 4.2 ms of GPU per
present at the 646 MHz clamp and presented about 30 % fewer frames.
