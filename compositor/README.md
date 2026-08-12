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

`--frames` and `--commit-seconds` remain available for bounded diagnostics.

Physical placement is configuration, not connector-order policy. An output
file contains one `NAME=X,Y[,REFRESH_HZ]` assignment per line. When refresh is
configured, Denial selects the matching mode at the connector's native
resolution; otherwise it selects the fastest native mode. Add `vrr=NAME` for
each output that should use variable refresh rate, or `disabled=NAME` to leave
a connected output outside the KMS and Wayland topology. Denial validates VRR
support on enabled connectors before committing the KMS state. Unlisted
outputs use the deterministic left-to-right fallback. Command-line position
assignments override the file:

```text
# ~/.config/denial/outputs.conf
DP-5=0,0,200
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

Measured on the current DP-4/DP-5 setup, the steady dual-output loop runs at
about 180 Hz (the slower output), with roughly 0.32 ms average render time while
the temporary software cursor uses a second GL pass.  A 2400-frame Vulkan
client run completed at 179.96 Hz before hotplug accounting; all finite runs
restored DP-5's original 60 Hz console mode and both original scanout buffers.
