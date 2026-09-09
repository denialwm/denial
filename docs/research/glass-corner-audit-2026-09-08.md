# Mobile glass corner audit — 2026-09-08

Audited Flutter engine: `814b06f098f2caf21b368b63f2275dca811da44f` in
`/mnt/exty/denial-flutter-fork-3.44.7`. This investigation reads the current
implementation; it does not infer the cause from commit history.

The user reports glass overflowing the mobile status dropdown's bottom rounded
corners, black corners on the volume/brightness HUD, and rectangular edge shine.
The running phone enables `DENIA_GLASS_DIRECT_MATERIAL=1` and
`DENIA_GLASS_POOLED_TARGET_PADDING=1`.

## Actual clip bypass

Both surfaces use `ShellBackdropBlur(separateChild: true)`. Its outer
`ClipRRect` is present (`dart_shell/lib/src/widgets/shell_backdrop_blur.dart:98`).
The engine builds the rounded clip through `DlDispatcherBase::clipRoundRect`,
`Canvas::ClipGeometry`, and `ClipContents::Render`. Impeller writes depth outside
the rounded shape to reject subsequent draws within that clip scope.

The failure is in the pipeline used to consume this clip:

1. `impeller/entity/contents/content_context.cc:723` creates the default glass
   pipeline with `options_no_msaa_no_depth_stencil`.
2. `ContentContextOptions::ApplyToPipelineDescriptor` clears its depth/stencil
   descriptors and pixel formats (`content_context.cc:447`).
3. Direct glass rendering requests options derived from the parent pass, which
   has depth/stencil attachments (`glass_filter_contents.cc:319`). Variants
   clone the already stripped default descriptor (`content_context.cc:189`).
4. Applying options with `has_depth_stencil_attachments=true` does **not** recreate
   the missing descriptors. It only checks their presence with `FML_DCHECK` and
   modifies descriptors that already exist. Release builds omit that check.
5. The GLES backend consequently renders with depth testing disabled
   (`impeller/renderer/backend/gles/render_pass_gles.cc:150`). The glass quad
   bypasses the rounded mask even though Canvas assigned it the right clip depth.

Ordinary blur draws its filter result through a texture pipeline, while this
optimization sends the glass shader directly into the parent target. That
explains the glass-specific failure. A cached glass snapshot also returns via
the texture pipeline, so direct and cached frames can behave differently.

## Shape orientation and rectangular shine

The dropdown supplies zero top radii and rounded bottom radii
(`dart_shell/lib/src/widgets/shade/quick_settings_panel.dart:100`). The physical
mobile view applies a root Y reflection
(`shell/platform/embedder/embedder_external_view_embedder.cc:116`).

Canvas transforms the full material bounds into target space, and
`GlassFilterContents::RenderFilter` generates target-space material positions.
However, it sends the corner radii in their original TL/TR/BR/BL order
(`impeller/entity/contents/filters/glass_filter_contents.cc:241`). The shader
selects corners using target-space Y (`impeller/entity/shaders/filters/glass.frag:43`).
The bottom rounded corners therefore receive the original square top-corner
radii. This makes the optical boundary and shine rectangular at those corners;
the missing depth test lets that incorrect boundary spill outside the UI clip.

## Black HUD corners

The symmetric HUD is unaffected by the corner permutation. Its shader correctly
outputs transparent black outside its own rounded shape, and fades alpha over
the two physical pixels inside the boundary (`glass.frag:189`). The direct draw
uses `BlendMode::kSrc` (`impeller/display_list/canvas.cc:2344`), which replaces
the destination rather than preserving it underneath transparent source pixels.

With clipping bypassed, the transparent black replaces the background across
the cut-out corners of the rectangular quad. Even after restoring clipping,
the shader's partially transparent inner edge still reduces destination alpha
under replacement blending. The material coverage/compositing contract needs
to preserve the scene at that transition.

## Nonvisual verification and fix boundary

CPU checks extracted the current shader distance functions and the current
pipeline attachment-transition code; small C++ adapters supplied vector math
and descriptor storage. No GPU rendering, screenshots, or UI triggers were used.

- The direct pipeline requested depth/stencil but retained neither descriptor.
  A clip-capable default retained clipping and could also produce an
  attachment-free offscreen variant.
- For a 320×200 dropdown with radius 20, local point (2,198) is outside the
  rounded corner by 5.45584 pixels. After reflection, the current shader reports
  distance −2 at (2,2), inside the square corner. Remapping the corner order
  restores the expected +5.45584 distance.
- At 0.5 pixels inside a symmetric curve, shader coverage is 0.156248.
  Source replacement changes backdrop (0.2,0.4,0.6,1) into approximately
  (0.03125,0.0625,0.09375,0.15625).

The focused fix should give glass a clip-capable default pipeline, keep shape
coordinates/corner identities consistent with the render transform, and preserve
the scene through material coverage. It must cover direct and cached/materialized
draws without changing the accepted optical defaults or globally changing the
shell's backdrop blend mode. Hardware visual confirmation remains user-owned.

The initial audit made no engine behavior changes and performed no build,
deployment, service restart, or reboot.

## Implemented correction

Flutter commit `59a828a046906f3643a922dfd7438339145a58d9`
(`Preserve rounded glass clipping and scene coverage`) implements the correction
in the canonical fork. Denial's source lock remains unchanged. The user visually
accepted this isolated experimental engine on 2026-09-08.

- The default glass pipeline retains depth/stencil support. An offscreen variant
  can remove those attachments without preventing a later direct variant from
  consuming the parent pass's rounded depth clip.
- Canvas supplies the full material transform. The glass SDF evaluates positions
  in physical material coordinates, keeping corner identities stable through
  reflection, rotation, translation, and partial frame damage. Its normals use
  the corresponding inverse transpose before refraction and lighting.
- Backdrop coverage interpolates between the original premultiplied scene and
  the glass material. Cut-out corners retain the background; the inner coverage
  transition no longer replaces it with partially transparent black. Ordinary
  image filters retain their transparent masking behavior.
- Direct rendering copies only the required scene region to independent storage
  before drawing, avoiding framebuffer sampling feedback on GLES. Zero frost
  and frost-allocation fallback include the optical sampling margin in this copy.
  Cached/offscreen materials use their existing scene snapshot. This introduces
  a bounded scene-copy pass for direct glass; its device performance has not
  been benchmarked in this work.

The accepted SDF, bevel, refraction, frost, tint, and lighting functions and all
tuning defaults are preserved. The changes are confined to the engine's glass
rendering path and its regression tests.

## Build and nonvisual validation

- Release `impeller_unittests`: 13/13 passed. These cover material coordinates,
  reflected/rotated damage, filter coverage, and creation of a clipped direct
  GLES pipeline after the offscreen pipeline has already been cached. GLES is
  mocked; these tests create no window or rendered output.
- An extracted shader coverage check passed 16 combinations of background alpha
  and material coverage, plus an ordinary-image-filter masking case. At coverage
  0.15625, opaque backdrop `(0.2,0.4,0.6,1)` and material `(0.6,0.2,0.8,1)` now
  produce `(0.2625,0.36875,0.63125,1)` rather than reducing the backdrop alpha.
- ARM64 release `libflutter_engine.so` and `libflutter_linux_gtk.so` built
  successfully. No debug/profile engines were built. The accepted release
  compositor, shell/settings AOT, and assets were reused byte-for-byte; no Dart
  or embedder ABI change requires rebuilding them.
- Candidate: `glass-corners-release-59a828a04690`. Engine SHA-256:
  `5ddb926162c1c5907b87060d557cb29d3bb132d30e447a358ed46ac463481687`.
- Build logs, test JSON, numerical check, packaging/deployment scripts, and the
  76-file candidate manifest are retained in
  `/mnt/development/moto70edge/build/denial-glass-corners-20260908`.

The user confirmed that everything works after checking the deployed glass fix
on 2026-09-08. The agent performed no screenshots, UI test events, or visual
inspection. The user explicitly forbids a device reboot; activation is
restricted to a Denial service restart.

## Moto deployment

The candidate is installed at
`/var/lib/moto70-denial/glass-corners-release-59a828a04690` on Moto serial
`ZY22MMG59D`. All 76 installed file checksums, native/GTK dependencies, and the
on-device release-engine ABI load test passed. The previously accepted candidate
remains available in its separate versioned directory.

`denial-moto70.service` restarted successfully: PID `1106` became `16253`, with
the new candidate's engine mapped and the service active/running. The boot ID
remained `7a3f8691-25c1-4a8a-a345-2593edce1fb4`; **no reboot occurred**. The
settings launcher now selects the matching release GTK engine. Activation and
hash evidence are retained in `service-restart.log` and `activation-health.log`
alongside the local candidate.

Runtime logs show frames continuing after activation. Startup still emits the
backing-store and EGL context-binding errors also present in the accepted
engine's process; these remain outside this glass fix. The comparison is saved
in `runtime-errors.log` and `baseline-runtime-errors.log`. The new service stayed
active/running with `Result=success` and no automatic restarts.

## Screen-off restart observation

On 2026-09-08, the user reported that Denial seems to restart without hanging
when the Moto's screen is already off. This records a useful observed condition
for future authorized restarts; repeated confirmation is still needed to establish
its reliability. The agent did not independently check or change the screen state.
