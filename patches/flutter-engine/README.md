# Denial Flutter Engine delta

## Pinned upstream revision

The patch in this directory targets Flutter Engine revision
`cb4b5fff73850b2e42bd4de7cb9a4310a78ac40d`.

Keep the revision, the patch, the prebuilt `libflutter_engine.so`, and its
license bundle versioned as one release unit. Do not silently apply the patch
to a different engine revision: rebase it and repeat the rendering and CPU
profile checks below.

The release unit lives in `prebuilt/flutter-engine/elinux-x64-release/`:
the patched binary, its SHA-256, the pinned revision, the GN `args.gn`, and
both license files are committed to Git so the compiled engine can never be
lost again. `prebuilt/.../BUILD_INFO.md` records where the engine build tree
lives and how to rebuild.

## How the patched engine reaches the bundle

`flutter-elinux build` unconditionally copies the STOCK Sony engine from the
SDK artifact cache into `dart_shell/build/.../bundle/lib/` and
`dart_shell/elinux/flutter/ephemeral/`. On 2026-07-19 this silently reverted
the bundle to the stock engine and brought the software A8 mask uploads back
(~956 window-sized `glTexSubImage2D` calls/s, ~20% of a core, measured live).

`tools/denial-pc` therefore enforces the patched engine at both ends:

- `bundle` (and `build`) finish by verifying
  `prebuilt/flutter-engine/elinux-x64-release/libflutter_engine.so` against
  its committed SHA-256 and installing it over the bundle and ephemeral
  copies (`install_patched_engine`).
- `session` refuses to start when the bundle engine's SHA-256 does not match
  the prebuilt stamp (`require_patched_engine`), so a stock engine can no
  longer run unnoticed.
- `doctor` reports whether both the prebuilt and the bundle engine are the
  patched build.

Building the bundle through anything other than `tools/denial-pc bundle`
leaves the stock engine in place by design of the upstream tool; the session
guard will catch it.

## Why Denial rebuilds Flutter Engine

Denial supplies Flutter with an embedder-owned OpenGL framebuffer. Upstream
`GPUSurfaceGLSkia` wraps that framebuffer as a Skia render target, but declares
both its sample count and stencil depth as zero, regardless of the actual FBO:

```text
GrBackendRenderTargets::MakeGL(width, height, 0, 0, framebuffer_info)
```

This metadata is part of Skia's rendering contract. Upstream also creates the
surface without `SkSurfaceProps::kDynamicMSAA_Flag`. In `ClipStack.cpp`, an
antialiased clip that cannot use either a multisample target or dynamic MSAA is
explicitly sent to a software texture mask. For Denial's large even-odd clip
around a window shadow, profiling showed that exact fallback: Skia repeatedly
generated large CPU A8 clip masks and uploaded them through
`glTexSubImage2D`. This was the measured CPU cost; it was not a CPU copy of the
imported game DMA-BUF.

There is a second, independent upstream policy in
`shell/common/context_options.cc`: every OpenGL context defaults to
`fAvoidStencilBuffers = true`. A runtime profile taken after only adding real
stencil metadata and dynamic MSAA still spent about 23% of one CPU in
`io.flutter.raster`, with samples in `SkScan::AAAFillPath` followed by
`GrGpu::writePixels`. The FBO reported eight stencil bits and wrapped
successfully, but this context option made `ClipStack` treat stencil as
unavailable anyway. Both engine changes are therefore required.

The first runtime with stencil genuinely enabled exposed a third issue in the
Ganesh GL path. Denial returns a different borrowed scanout FBO after every
present. Dynamic MSAA creates a private multisample FBO for each wrapped
target, but `GrGLRenderTarget::onRelease()` used the ownership of the borrowed
single-sample FBO to decide whether *all* FBO IDs should be deleted. The
private DMSAA FBO was consequently leaked. Its deleted renderbuffer
attachments can remain referenced by that leaked FBO, which turns a small GL
object leak into potentially very large retained GPU allocations. If the
multisample color allocation then failed, `ensureDynamicMSAAAttachment()` also
left the incomplete FBO ID installed and treated it as valid on the next call.

The same test exposed a stencil-continuity hole across split Ganesh OpsTasks.
A draw that writes stencil forces dynamic MSAA, while a later draw that only
*consumes* the resulting stencil clip did not. It could therefore reload the
preserved clip from Denial's unrelated single-sample stencil attachment. In a
71.5-second failing session Denial produced 4,120 raster frames, showed no
AMDGPU reset or EGL/FBO error in the journal, and used only 5.64 CPU seconds at
the service level; the severe visual corruption was therefore consistent with
the two GPU-state/lifetime errors rather than the original CPU mask path.

The follow-up visual test isolated another, more fundamental GLES-only load
failure. OpenGL ES forbids blitting a single-sample framebuffer into an MSAA
framebuffer. Ganesh falls back to `drawSingleIntoMSAAFBO()`, which samples the
single-sample target as a texture. Flutter's normal onscreen GL path wraps only
the embedder's FBO ID, however, so the same target reports `asTexture() ==
nullptr`; `copySurfaceAsDraw()` returns false and that result is ignored. The
dynamic-MSAA attachment is then used without loading the pixels it must
preserve. Partial repaint makes the failure visible as stale window copies,
damage trails, and regions that become correct when pointer damage crosses
them. Simple pages that do not need the stencil/MSAA path remain unaffected.

After repairing that load path, per-operation GL telemetry exposed a fourth
issue in the final MSAA resolve. Denial allocates its scanout buffers as
`DRM_FORMAT_XRGB8888`; Mesa correctly exposes the imported EGLImage texture as
`GL_RGB8` with no alpha channel. Flutter nevertheless described every onscreen
target as `GL_RGBA8`, so Ganesh allocated a four-sample `GL_RGBA8` renderbuffer
and attempted to resolve it into the single-sample `GL_RGB8` scanout texture.
Both FBOs were complete, but GLES rejects that format-mismatched multisample
blit with `GL_INVALID_OPERATION`. Disabling invalidation, forcing full bounds,
and inserting `glFinish()` did not change the corruption because the resolve
itself never happened. The same trace showed successful `R8 -> R8` resolves,
isolating the failure to the incorrect atlas format.

With the target described as `GL_RGB8`, Ganesh creates a matching four-sample
`GL_RGB8` attachment. The validation run recorded 512 consecutive resolves
with no query, blit, or invalidation error, including all atlas resolves. The
temporary probes used to establish those facts are not part of the production
patch set or launcher.

The direct texture path exposed a fifth issue specifically in the partial
dynamic-MSAA load. Ganesh copies the exact native-device rectangle with a tiny
internal shader, but declares its vertex positions, texture coordinates and
coordinate transforms as `half`. On GLES this is mediump/binary16 precision.
Near normalized coordinate 1.0, consecutive values are 1/1024 apart: on
Denial's 5120-pixel atlas that is five pixels, not one. Full-surface copies use
the exactly representable endpoints 0 and 1, while pointer-driven partial
rectangles can therefore sample or place a horizontally shifted strip.

The public Flutter embedder API has no field through which Denial can correct
the sample-count, stencil metadata, or actual format of an FBO returned by the
root-surface callback. Therefore this part of the fix cannot be implemented
only in Denial: `libflutter_engine.so` must be rebuilt.

## What the engine patches do

After Flutter asks the embedder for the current FBO,
`0001-query-embedder-fbo-capabilities.patch`:

1. binds that FBO;
2. queries its real `GL_SAMPLES` and `GL_STENCIL_BITS` values;
3. passes those values to `GrBackendRenderTargets::MakeGL`;
4. enables Skia's dynamic-MSAA surface property.

`0002-enable-stencil-for-gl-surfaces.patch` overrides Flutter's generic
OpenGL policy for `GPUSurfaceGLSkia` and sets `fAvoidStencilBuffers = false`.
This lets Ganesh use the stencil bits described by patch 0001. Without patch
0002, the real attachment is deliberately ignored and the software A8
fallback remains active.

`0003-fix-dmsaa-wrapped-fbo-lifetime-and-stencil.patch` changes Ganesh itself
in three narrowly scoped ways:

1. deletes the internally owned DMSAA FBO even when the final single-sample
   FBO is borrowed;
2. clears and deletes a newly generated FBO if its multisample color
   attachment cannot be allocated;
3. keeps draws that consume a stencil clip on the DMSAA attachment, so an
   OpsTask split cannot switch to a different stencil domain.

`0004-wrap-texture-backed-fbos-for-dmsaa-load.patch` detects the level-zero GL
texture attached to an embedder FBO and wraps that borrowed texture as the Skia
render target. Ganesh can then sample the existing single-sample pixels when it
loads a dynamic-MSAA pass on GLES. The Skia FBO and stencil state point at the
same EGLImage storage, so this adds no color-buffer copy. If an embedder FBO is
not backed by a compatible 2D texture, the patch leaves dynamic MSAA disabled
for that target instead of using an undefined load path.

`0005-describe-xrgb-scanout-as-rgb8.patch` queries the attached texture's real
level-zero internal format. When EGL exposes an opaque XRGB scanout image as
`GL_RGB8`, Flutter wraps it as `kRGB_888x_SkColorType`/`GL_RGB8` instead of
claiming `GL_RGBA8`. Ganesh consequently allocates a matching RGB8 dynamic-MSAA
attachment and the standard GLES resolve succeeds. The query preserves the
previous texture binding. This changes metadata only: it adds neither a CPU
copy, an intermediate texture, nor another GPU pass.

`0006-use-highp-for-partial-dmsaa-load.patch` changes only the coordinate types
in Ganesh's internal GL copy shader from `half` to `float`. Color values retain
their existing precision. The partial DMSAA load remains a one-to-one GPU copy
of the exact damage bounds, but a 5120-pixel target can now address every pixel
without coordinate quantization. It adds no pass, allocation, or CPU work.

None of the six patches changes Dart, widgets, themes, shadows, clipping
geometry, or Flutter layout. They describe the native target accurately and
repair the lifetime/state invariants needed by the GPU implementation.

## What Denial supplies

The matching code is in
`compositor/src/bin/deniald/flutter_runtime.rs`. For every Flutter target it
keeps the existing single-sample EGLImage/DMA-BUF color texture and attaches an
8-bit single-sample stencil renderbuffer to the same FBO. Flutter therefore
draws directly into the scanout DMA-BUF; Denial does not allocate a permanent
multisample color target and does not perform a full-frame blit in `present()`.

When an operation needs smooth stencil coverage, Skia's dynamic-MSAA path owns
a temporary multisample attachment, renders that operation on the GPU, and
resolves it into the direct target. Ordinary draws remain on the direct target.
Imported game textures continue to use EGLImage/DMA-BUF without a CPU staging
copy.

The six engine patches and the Denial half are intentionally paired.
Shipping only the engine patches leaves the old Denial FBO without stencil;
shipping only the Denial FBO leaves upstream Flutter reporting `0/0`,
dynamic MSAA disabled, and its OpenGL stencil-avoidance policy enabled.

## Validation required for every rebase

- Build the engine in release mode and build `deniald` with the `flutter`
  feature.
- Verify at runtime that the selected direct Flutter FBO is single-sample and
  reports 8 stencil bits.
- Verify that Skia can create its dynamic-MSAA attachment without framebuffer
  completeness or resolve errors.
- On GLES, verify that the wrapped scanout target is texture-backed and that a
  DMSAA load samples the existing EGLImage pixels instead of attempting the
  unsupported single-sample-to-MSAA blit or using an uninitialized attachment.
- Verify that an XRGB8888 EGLImage is wrapped as `GL_RGB8`/`kRGB_888x` and that
  both sides of every atlas resolve use `GL_RGB8`; an RGBA8-to-RGB8 resolve is
  invalid even when both FBOs are individually complete.
- Exercise small pointer-driven partial DMSAA loads across the full atlas and
  verify that high-precision copy coordinates never produce shifted horizontal
  bands or stale strips, especially near the right edge of a 5120-pixel target.
- Run long enough to cycle thousands of borrowed FBO wrappers; verify that
  private DMSAA FBOs and their attachments are released instead of growing
  monotonically.
- Exercise render-pass splits while an antialiased stencil clip is live and
  verify that every stencil consumer remains on the DMSAA attachment.
- Verify that the OpenGL Ganesh context has stencil avoidance disabled; real
  stencil metadata alone is insufficient.
- Exercise a game spanning both outputs with the normal Flutter shadow and
  complex clip unchanged.
- Profile Flutter's raster thread and confirm that the previous large repeated
  A8 `glTexSubImage2D` uploads have disappeared or become negligible.
- Check frame damage, output transforms, native fence ordering, resizing, and
  teardown on all supported GPUs.
- Record the before/after CPU figures with the same game, scene, resolution,
  and frame-rate cap.

## Distribution

Flutter Engine is licensed under the BSD 3-Clause license and permits binary
redistribution with or without modification. A Denial release containing the
custom `libflutter_engine.so` must also contain:

- the Flutter Engine `LICENSE` for the pinned revision;
- the generated cumulative third-party license file from
  `flutter/sky/packages/sky_engine/LICENSE`;
- no wording that implies Google or Flutter contributors endorse Denial.

End users install the prebuilt engine as part of Denial. They do not need a
Flutter checkout or a local engine build.
