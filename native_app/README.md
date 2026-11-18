# Minimal native Flutter app runner

`denial-app` runs an existing release AOT bundle in its own Wayland process.
It reuses Denial's raw engine host, text editor and cursor decoder. Settings,
Welcome, Plugin Manager and the Polkit dialog use this runner for their windows
and input; none links a GTK runner. Flutter assets are assembled directly.

The rendering path is Flutter → reusable RGBA8 framebuffer → GPU blit →
alpha-capable EGL/Wayland window. Denial still supplies the desktop glass.
The runner preserves the application's alpha; it does not synthesize blur.
Before graphics startup, it appends `-GL_EXT_shader_framebuffer_fetch` to
`MESA_EXTENSION_OVERRIDE`, preserving other overrides. This avoids the engine
buffer transition that corrupts layers below the final backdrop filter on .188.
The workaround affects this app process; Denial's shell keeps its capabilities.
Old-size frames are discarded during resize. Frame callbacks pace animation;
the event loop sleeps until Wayland events or engine task deadlines arrive.

Build from the repository root (native dependencies: Wayland, EGL, GLES3,
libxkbcommon):

```sh
cargo build --manifest-path native_app/Cargo.toml --release --locked
cargo test --manifest-path native_app/Cargo.toml --locked
cargo clippy --manifest-path native_app/Cargo.toml --all-targets --locked -- -D warnings
```

Run from an existing Wayland terminal:

```sh
native_app/target/release/denial-app \
  --bundle plugin_manager_app/build/linux/x64/release/bundle \
  --engine dart_shell/build/linux/x64/release/bundle/lib/libflutter_engine.so \
  --app-id dev.denial.PluginManager --title 'Denial Plugins'
```

`--overlay` presents a centered, undecorated wlr-layer-shell surface on the
overlay layer instead of a window. It takes exclusive keyboard focus, uses the
app ID as its namespace, and has the fixed `--width` and `--height`; the
application paints any transparency around its content. The Polkit dialog uses
it.

`--check` validates bundle components, AOT loading and the raw engine ABI
without starting Flutter or opening a window. Impeller is the default.
This repository builds Slimpeller, so Skia is unavailable in its engine.

The runner supports one window/view and seat, integer display scaling, resize,
pointer/buttons/scrolling, multi-touch, keyboard layout/compose/repeat, basic text
editing, cursor shapes and window close. Dart entrypoint arguments follow `--`.
The installed `denial-plugin-manager` executable finds its adjacent bundle and
retains its installation descriptor beside the runner. Settings is not a
Flutter application: see `settings/README.md`.

File selection uses the external FileChooser portal. The portal backend can be supplied by any desktop toolkit;
it does not handle Denial application windows or input. Accessibility, external
IME, clipboard, activation/single-instance handling and platform plugins
remain outside this runner's current scope.

Flutter's Linux key-event JSON codec calls its XKB format `gtk`. That protocol
label remains required by Flutter; the runner obtains keyboard events directly
from Wayland and never calls GTK.

The source inclusion of the two private input modules is deliberate read-only
reuse for this first version. A small transaction type adapter satisfies the
text editor's import. This creates a checkout dependency, not a new public SDK
contract; extracting those modules later would require a separate Denial change.

Difficulty: moderate for this MVP because engine startup and platform logic
already exist. Correct GPU ownership, resize commits and scheduling are the
hard parts. Broader platform-plugin compatibility is a larger follow-up.
The user validated correct rendering and glass on .188 with framebuffer fetch
disabled on 2026-09-30. All standalone Denial apps now share that process-local
workaround through this runner.

## Native application extensions

The `denial_app` library offers `run_with_extension(config, AppExtension)` for
applications that supply their own native content. The CLI uses an empty
extension; installed applications retain their existing startup, rendering and
platform handlers. The engine fork and Denial compositor require no changes.

An extension can register positive, unique `RgbaTexture` IDs and an optional
`PlatformMessageHandler`. In Dart, display a texture with
`Texture(textureId: id)`. Native workers publish `RgbaFrame` values containing
tightly packed, top-to-bottom, premultiplied sRGB RGBA8 pixels. Each dimension
is limited to 4096 and frames to 64 MiB. Each texture keeps the latest frame
and coalesces event-loop notifications; publishing never accesses GLES or
Flutter. The raster thread uploads only new generations, preserves engine GL
state and releases textures during render-thread shutdown. This initial API
uses a CPU upload; it does not import DMA-BUF or share Vulkan textures.

Platform handlers receive channel names and codec bytes on the window event
loop. Return `None` to leave a message unhandled, or encoded reply bytes for
your application's channel. Built-in text input, cursor, navigation and portal
plugins run first. Queue expensive work on a worker rather than blocking the
handler. Call `prepare_graphics_environment()` before starting threads or
graphics to apply the same Mesa workaround as the CLI.

Synthia uses this API for a Bevy viewport and JSON method-channel settings.
Texture mailbox bounds, replacement, notification coalescing and detach behavior
are covered by native unit tests; GUI/rendering validation remains user-owned.
