# Native mobile app insets

The mobile compositor reserves **48 logical pixels** above ordinary app
content, matching the current status bar. Output scaling converts that to
physical pixels. For a 400×900 logical output at 2× scale, the client receives
a 400×852 configure and can supply an 800×1704 buffer; its presented window
canvas is 800×1800, including a 96-pixel status strip. The larger canvas is
metadata, not a larger allocation.

## Client declaration

[`denial-insets-v1.xml`](../compositor/protocol/denial-insets-v1.xml) adds one
optional global, `denial_insets_manager_v1`. An application that already knows
and applies its system insets calls `set_self_managed(wl_surface)` before its
initial buffer commit. In Droidloom this is immediately before the initial
task-window commit:

```rust
if let Some(manager) = &self.insets_manager {
    manager.set_self_managed(window.wl_surface());
}
```

The declaration belongs to the surface, survives unmap/remap and destruction
of the manager binding, and is idempotent. A first declaration while a buffer
is committed is a protocol error. It may also be made while unmapped. There
is no per-frame request, new surface role, app-ID allowlist, or inset-size
event. A declaring client is responsible for supplying the actual inset
information to its application. Other compositors need not expose the global.

This request is explicitly immediate state, unlike the buffer and other
double-buffered state applied by `wl_surface.commit`; see the
[Wayland protocol specification](https://wayland.freedesktop.org/docs/html/apa.html).
Popups and subsurfaces continue using their owning toplevel's coordinates.
Desktop layout remains unaffected.

## Geometry and rendering

`wayland_frontend/insets.rs` owns mobile client geometry before the first
buffer. The existing exact-geometry policy preserves it across client size
requests, and topology changes recompute it. XDG configure bounds and popup
constraints use that same client area. Ordinary XWayland application windows
follow the policy; override-redirect surfaces keep their existing role.

The full scene snapshot carries separate client-content and presentation
bounds using existing wire fields. Only the root texture receives a virtual
canvas. Child surfaces retain their protocol identities; clipping adjusts
their source/destination rectangles, and fully clipped children are not
painted or held waiting for a sample. Buffer-only updates keep their fast path.

The engine's optional external-texture presentation callback supplies the
original source rectangle, destination, canvas dimensions and status strip.
Presentation metadata advances with its corresponding queued buffer. The
engine reads it when resolving an image and retains it with that image;
retained paints do not call back into Rust.

Painting uses two quads in the existing `TextureLayer`: the app and its status
strip. The strip samples the texel at offset `(5, 5)` from the visible source's
top-left corner, in actual buffer pixels. Small or cropped buffers clamp the
coordinate to a texel intersecting their visible source. An empty source uses
the original black fallback.

The engine retains only the sample rectangle alongside the resolved image.
Drawing stretches that 1×1 source across the strip with nearest-neighbour
sampling and a strict source constraint. Impeller's existing strict texture
shader clamps all sample coordinates to the texel centre; the ordinary Skia
image path receives the same constraint. The sampled RGBA, including alpha,
receives the same inherited paint and animation opacity as the app below it.
This is one pixel at `(5, 5)`, not an average of a 5×5 region.

The strip and app sample the **same displayed image**, so the colour changes
with every presented app frame, including buffer-only updates. There is no
timer, CPU colour readback, new frame scheduling, header image, app-buffer copy,
offscreen render target or inset `saveLayer`. The textured strip replaces the
previous solid quad; it does not add another quad or enlarge the painted area.
It does add texture sampling, using one texel throughout the strip, and the
existing cached sampler/pipeline. This is expected to be inexpensive, but no
measured frame-time or literal zero-cost claim is made. See the
[Khronos sampling reference](https://wikis.khronos.org/opengl/Template:Glapi_sampler_parameters)
for nearest-neighbour sampling semantics.

The separately exported engine extension and standard `FlutterOpenGLTexture`
ABI are unchanged. Colour sampling is implemented entirely in the engine;
native geometry, Flutter UI and Droidloom need no executable changes.

The mobile Flutter wrapper no longer builds an animated header, calculates
synthetic texture heights, or sends post-frame viewport corrections. Input
mapping uses the native content and frame bounds with the same top-centred
`BoxFit.cover` transform as presentation, including client-decoration offsets
and pending resizes. In-bundle Flutter apps receive safe-area metadata instead
of a separately painted header.

## Validation and build coupling

The x86-64 release engine and shell AOT builds, Rust compositor build and
`cargo check -p droidloom-wayland` passed. Shell analysis reported no errors;
five existing diagnostics remain in unchanged desktop files. No unit tests,
screenshots, app launches or interactive test events were run.

Use the matching engine containing Flutter fork commit `490107e1` with this
compositor: that commit introduces
`DenialFlutterEngineSetExternalTexturePresentationCallback`. The source lock
has not been advanced. The isolated release candidate and manifest live under
`/mnt/exty/denial-insets-20260905/`; that x86-64 candidate has not been deployed.

An Aston ARM64 release candidate is also packaged under
`/mnt/development/denial-ace3/work/native-insets-20260905/` (`current.json`
identifies the archive and checksums). It includes the compositor, shell
AOT/assets, matching engine/ICU, native tools, and the successfully cross-built
Droidloom Wayland presenter. Its engine is commit `00b84636`, which includes
the inset renderer and the subsequent glass damage-crop geometry fix. ARM64
ELF architecture, required engine exports and AOT snapshot metadata were
checked. The candidate was deployed to Aston, including its Droidloom presenter.
The authorized Denial restart reproduced the kernel hang while exiting the
previous `profile-a972794f-47f44948` candidate. Device actions stopped when SSH
was lost; the user rebooted Aston manually.

After that reboot, Denial PID `485` and Droidloom PID `545` were confirmed
active on boot `b9d4dd31-a11a-450f-9229-43ff618e186e`. The native executable,
mapped engine and AOT files, presenter and installed native tools match the
candidate hashes. `deployment-verified.json` records the checks. The previous
candidate remains available, and service configuration/executable backups are
under `/var/lib/denial/deployment-backups/native-insets-00b84636-34dd6451`.
Session-restart kernel hangs remain unresolved. SSH recovery now uses the
persistent host identity `/home/logix/.ssh/id_ed25519` via `NYX_SSH_KEY`, with
`NYX_SSH_KNOWN_HOSTS=/home/logix/.ssh/known_hosts`; the old key in `out/` was lost.

## GPU colour follow-up

Engine commit `22916303e85e46bbf274b71ad8c6a992ff2000c3` replaces the solid
strip with the GPU sample described above. ARM64 and x86-64 release engine
builds passed. The existing `TextureLayer` damage region includes the whole
virtual canvas, so an app-frame notification also repaints its strip; no new
damage propagation or frame scheduling is required.

The ARM candidate is
`/mnt/development/denial-ace3/work/inset-colour-20260905/inset-colour-arm64-release-22916303-34dd6451.tar.gz`.
All 48 archived files were verified. It reuses the accepted compositor, shell,
ICU, native tools and Droidloom presenter byte-for-byte and replaces only the
engine. The embedder ABI and snapshot generator are unchanged. `current.json`
beside the archive records the hashes and the separately staged x86-64 engine.
This follow-up is deployed on Aston. Installation verified all 48 files and
preserved the active session while selecting the new candidate. The user then
explicitly requested a session restart, offering to force-reboot if it hung.
The candidate was subsequently verified on boot
`59dae583-149d-4578-bdd7-02982f626af4`, with Denial PID `483` and the expected
engine/AOT mappings and hashes. The user confirmed the sampled fill works
visually. `deployment-verified.json` beside the candidate records acceptance.
Activation was observed after reboot; this does not establish a successful
session handoff or fix the known kernel hang. No unit tests, benchmarks or
agent visual validation were performed for the colour change.
