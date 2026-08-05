# Impeller implementation reference

## Goal

Maintain runtime-selectable Impeller GLES without weakening the existing
Skia/Ganesh path. One non-SLIMPELLER engine library contains both renderers.
Impeller is the default after passing Denial's correctness and performance
gates; Skia remains the explicit compatibility fallback. Vulkan Impeller is
out of scope: Denial's root atlas and Wayland external textures already share
EGL/GLES objects.

The expected payoff after parity work is lower p95/p99 raster latency and fewer
first-use shader/pipeline spikes. Do not assume higher average FPS, lower VRAM,
or lower power; measure them. Denial's Ganesh path is already heavily tuned.

## Selection

- `RendererBackend::{SkiaGles, ImpellerGles}` propagates through
  `FlutterRuntimeFactory` and atlas target creation.
- `--flutter-renderer skia|impeller` defaults to `impeller`; `skia` is the
  explicit fallback.
- Pass `--enable-impeller=true` only for `ImpellerGles`. The renderer config
  remains `kOpenGL`; no embedder ABI or bindgen change is required.
- Log the selected backend at engine start. A backend change requires a Flutter
  engine restart, never a graphical-session restart.

## First correct implementation

Patch the Denial Flutter fork's `GPUSurfaceGLImpeller`:

1. Present the exact FBO returned by `GLContextFBO`; upstream currently reports
   FBO 0 and null damage.
2. Treat Denial's returned FBO 0 as a no-target frame: do not encode GL work,
   but complete the present/producer transaction as a skipped frame.
3. Disable GL Impeller partial repaint initially and present full-frame plus
   full-buffer damage. Null/empty damage is not a substitute for full damage.
4. Check `SurfaceGLES::WrapFBO` before dereferencing it and fail the frame
   without crossing a fatal validation path.
5. Verify output and external-texture orientation. GL Impeller currently
   ignores the embedder root-surface transform; patch it only if the existing
   Impeller top-left coordinate conversion does not already produce the correct
   scanout orientation.

For Impeller only, give every atlas FBO a valid packed depth/stencil attachment.
One full-atlas renderbuffer may be shared by all rotating FBOs because raster
submission is serial and Impeller clears it per pass. Keep Ganesh's current
texture-backed FBO path unchanged. Validate FBO completeness and stencil bits.

Preserve these invariants:

- the FBO marked `Rendering` is the same nonzero FBO passed to `mark_ready`;
- FBO 0 is never rendered, fenced, or published;
- the exported EGL fence follows all Impeller commands;
- dma-buf/SHM external textures remain 2D RGBA8 with destruction callbacks;
- sampled client buffers remain held through the exported render fence.

## Parity optimization

Only advertise partial repaint after the Impeller GLES surface can preserve the
selected buffer: use load rather than unconditional color clear for partial
frames, clear/paint the required region, and report exact frame/buffer damage.
Retain Denial's existing Impeller 70% repaint-economics policy.

Cache Impeller wrappers/render targets per rotating FBO; the current path
recreates them per frame. Profile external-texture reactor cleanup, backdrop
filters, XRGB/RGB8 atlas description, AA quality, and the fact that pinned GL
Impeller disables Flutter's raster cache.

## Required validation

- Engine tests: selected FBO propagation, full damage, FBO-0 skip, wrapper
  failure, external-texture cleanup, and both renderer selections.
- Rust tests: option parsing, backend propagation, target cleanup, broker and
  fence invariants.
- Real session: multi-output pool pressure, 120/240 Hz animation, dma-buf and
  SHM windows, Xwayland/Vulkan clients, blur/rounded clips, lock screen, DPMS,
  hotplug, screencopy, and engine restart.
- Compare Skia and Impeller render-audit output, screenshots, CPU/GPU profiles,
  frame-time p50/p95/p99, VRAM, and power on Intel, AMD, and NVIDIA/Mesa.

Impeller became the default only after real-session validation established
correctness parity and strong interactive behavior. Continue comparing tail
latency, throughput, memory, and power on every supported GPU family; the Skia
fallback remains part of the supported runtime contract.
