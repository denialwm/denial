# Denial compositor

The Rust workspace contains four deliberately separate layers:

- a pure topology/atlas model with atomic hotplug transactions;
- a nested visual harness for development inside another compositor;
- a real Smithay DRM/KMS compositor using libseat, GBM/EGL, libinput, udev and
  a Wayland frontend; and
- a shell-independent native control client for the compositor's versioned
  per-user IPC.

The KMS backend allocates one desktop-wide XRGB8888 GBM atlas.  Every connected
CRTC scans a different source rectangle of that same framebuffer; there is no
per-output copy. Flutter uses one global atlas pool sized for independently
clocked output ownership. Pathological layouts are rejected before GBM
allocation if either atlas axis exceeds 16384 pixels or the complete pool
exceeds 1 GiB. The pre-Denial atomic state and framebuffer objects are pinned
before the first modeset and restored on normal exit.

## Fast checks

```sh
cargo test --manifest-path compositor/Cargo.toml --lib --bins --tests \
  --features flutter
cargo clippy --manifest-path compositor/Cargo.toml --all-targets \
  --features flutter -- -D warnings
```

The optional Rust Flutter host compiles the committed, revision-stamped
Flutter Embedder API bindings and verifies them against the locally staged
engine and AOT library. Normal builds do not need Clang or libclang:

```sh
cargo test --manifest-path compositor/Cargo.toml -p denial-flutter-engine
```

Only a controlled Flutter engine upgrade regenerates the bindings:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

## Nested harness

```sh
cargo run --release --features nested --manifest-path compositor/Cargo.toml \
  --bin denial-nested -- \
  --cycle-ms 2500 --exit-after-ms 10000
```

Presets are `horizontal`, `vertical`, `l-shape`, and `mixed`.  The harness does
not open DRM, libinput or system services.

## Real DRM/KMS backend

Run these only from the active text VT with no other compositor owning the
target DRM device.  Every finite command below restores the captured state:

```sh
cargo build --release --features kms --manifest-path compositor/Cargo.toml \
  --bin deniald

compositor/target/release/deniald --frames 60
compositor/target/release/deniald \
  --frames 2400 --wayland
```

With the Flutter shell, omitting the finite harness limits starts the normal
session loop. It keeps running until the shell requests logout; the existing
normal-exit path then restores the captured atomic KMS state:

```sh
cargo build --release --features flutter --manifest-path compositor/Cargo.toml \
  --bin deniald --bin denialctl

compositor/target/release/deniald \
  --wayland --flutter-bundle /path/to/denial/bundle
```

The `flutter` feature includes `kms`; a binary built with only `kms` cannot
load the Flutter bundle. While that session is running,
`compositor/target/release/denialctl status` inspects its output and Flutter UI
state without depending on the shell.

The KMS compositor starts a rootless Xwayland server and exports its dynamic
`DISPLAY` alongside `WAYLAND_DISPLAY`. Install the system `Xwayland` executable
to run X11-only applications such as Steam; the development session fails
early with a clear error when it is absent.

Denial remembers the last normal rectangle and maximized/fullscreen state of
each application and restores them before that application's first frame is
configured. Native Wayland windows use `xdg_toplevel.app_id`; managed X11
windows use `WM_CLASS`. Records are kept output-relative by connector, so
rearranging monitors preserves the intended screen while disconnected or
smaller outputs fall back safely and clamp the window on-screen. Transient
windows retain normal compositor placement; every non-transient toplevel is
eligible for restoration, including new windows opened by single-instance
applications.

The Desktop Layout settings page can switch window placement between
`stacking` and `dwindle` at runtime. Stacking preserves Denial's freely
overlapping placement. Dwindle follows Hyprland's binary-tree model: a new
window splits the focused tile, each parent chooses its split direction from
its current aspect ratio, and removing a window collapses the empty branch.
The existing maximize padding is also used as the gap between sibling tiles.
Transient dialogs, fixed-size toplevels, auxiliary X11 window types, and
override-redirect X11 surfaces remain floating, while maximized and fullscreen
windows temporarily cover their retained tile. Hold SUPER and left-drag a tile
onto another tile to swap their leaves without rebuilding the tree. Switching
back to stacking restores the windows' pre-tiling rectangles.

Layout algorithms are protocol-independent implementations of `WindowLayout`
in `src/bin/deniald/window_layout.rs`. To add one, implement that trait and add
it to `WindowLayoutKind` and `create_window_layout`; the Smithay adapter owns
window eligibility, output work areas, saved stacking geometry, and protocol
configures, so a layout implementation only manages IDs and returns logical
rectangles.

The bounded state file is written atomically at
`${XDG_STATE_HOME:-$HOME/.local/state}/denial/window-placements.json`. Removing
that file resets remembered placements.

For the first full-session attempt on the current development workstation,
keep teardown bounded while exercising the real Flutter/Wayland path:

```sh
compositor/target/release/deniald \
  --output-config dev/denial-outputs.conf \
  --wayland --flutter-bundle dart_shell/build/linux/x64/release/bundle \
  --commit-seconds 120
```

The process restores the captured KMS state when the limit expires. It also
reserves `Ctrl+Alt+Backspace` as a compositor-level graceful escape before
input is routed to Flutter or Wayland clients.

`Super+Escape` is the compositor-owned pointer escape. It releases a client
pointer lock or grab without forwarding Escape, keeps replacement constraints
disabled, and lets that client capture the pointer again only after a plain
click on its window.

Direct touch uses a small compositor-owned gesture vocabulary over normal
windows. Dragging within the top 48 logical pixels moves the window, pinching
anywhere resizes it about its center, a two-finger downward swipe begun in that
top strip minimizes it, and three simultaneous contacts close it. Recognition
is resolved before ordinary touch routing; when a later finger promotes a
client touch to a window gesture, Denial cancels that client sequence and emits
the same placement, minimize, and close actions used by non-touch controls.

`--frames` and `--commit-seconds` remain available for bounded diagnostics.

Physical placement is configuration, not connector-order policy. An output
file contains one `NAME=X,Y[,REFRESH_HZ]` assignment per line. When refresh is
configured, Denial selects the matching mode at the connector's native
resolution; otherwise it selects the fastest native mode. Set `primary=NAME`
to choose the display that owns primary shell surfaces and the render ticker;
when omitted or temporarily disconnected, Denial uses the enabled output with
the highest refresh rate. Use
`transform=NAME,normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270`
for rotation and reflection. Add `vrr=NAME` for each output that should use
variable refresh rate, or `disabled=NAME` to leave a connected output outside
the KMS and Wayland topology. Flutter projects transformed outputs directly
into their native, unrotated scanout buffers; the KMS mode and primary-plane
rotation remain unchanged, including for 90/270-degree transforms. Denial
validates mode and VRR changes with an atomic `TEST_ONLY` commit before
changing live KMS state. Unlisted outputs use the deterministic left-to-right
fallback.

When `iio-sensor-proxy` exposes an accelerometer, Denial automatically rotates
built-in `DSI-*`, `eDP-*`, and `LVDS-*` panels. The configured `transform=` is
the panel's fixed mounting transform; sensor rotation is transient and is not
written back to the output file. Sensor and manual transform-only changes keep
the Flutter engine, native output buffers, and compressed/tiled modifiers
resident. Automatic cardinal changes animate the retained composited scene for
300 ms on the physical output clock. The old-size scene starts rotating first;
Flutter receives the new logical canvas during the final quarter. Projection-
only frames do not drive Dart or advance client textures.
Command-line position assignments override the file:

```text
# ~/.config/denial/outputs.conf
primary=DP-5
DP-5=0,0,200
transform=DP-5,90
DP-4=2560,0,180
vrr=DP-4
disabled=HDMI-A-1
```

```sh
compositor/target/release/deniald \
  --output-config ~/.config/denial/outputs.conf --frames 60
```

Dynamic-layout and hotplug regression harnesses:

```sh
compositor/target/release/deniald \
  --frames 120 --reconfigure-at-frame 60 \
  --next-output-position DP-4=0,0 \
  --next-output-position DP-5=0,1440

compositor/target/release/deniald \
  --frames 150 --wayland --simulate-hotplug-at-frame 60
```

With `--wayland`, the process advertises physical `wl_output` globals, XDG
shell, SHM, `wp_viewporter` crop-and-scale support, `linux-dmabuf` v4 feedback
for the EGL render node, and `zwlr-output-power-management-v1`. It also advertises
`zwlr-screencopy-unstable-v1` version 3 with SHM and XRGB8888 DMA-BUF capture;
the latter keeps the frame transfer on the GPU for compatible screen recorders
and PipeWire portal backends. The Flutter Settings app also configures a
compositor-owned inactivity timeout. Mouse, keyboard, touch, tablet and Linux
joystick activity reset it; visible clients can keep displays awake with
`zwp_idle_inhibit_manager_v1`, as media players do during playback. DPMS-off
outputs remain in the logical desktop while their KMS pipeline is disabled;
waking them restores a complete scanout atlas without rebuilding the Wayland
topology. A Vulkan Wayland client has been validated through DP-5
removal/reconnection while its four dma-bufs remained imported and the client
kept presenting.

Denial also owns the desktop application colour-scheme and accent preferences.
Committed settings select the Flutter shell's semantic dark/light theme;
Flutter resolves custom or wallpaper-derived accent color, and deniald copies
the complete state as a bounded snapshot to the separate `denial-portal`
process. That helper implements `org.freedesktop.impl.portal.Settings`; it
neither parses the settings document nor runs D-Bus work on the compositor
event loop.

Measured on the current DP-4/DP-5 setup, the steady dual-output loop runs at
about 180 Hz (the slower output), with roughly 0.32 ms average render time while
the temporary software cursor uses a second GL pass.  A 2400-frame Vulkan
client run completed at 179.96 Hz before hotplug accounting; all finite runs
restored DP-5's original 60 Hz console mode and both original scanout buffers.
