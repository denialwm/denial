# Denial compositor

The Rust workspace contains three deliberately separate layers:

- a pure topology/atlas model with atomic hotplug transactions;
- a nested visual harness for development inside another compositor;
- a real Smithay DRM/KMS compositor using libseat, GBM/EGL, libinput, udev and
  a Wayland frontend.

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

The optional Rust Flutter host generates bindings from the vendored
`embedder.h` and verifies them against the bundled engine and AOT library:

```sh
LIBCLANG_PATH=/usr/lib cargo test \
  --manifest-path compositor/Cargo.toml -p denial-flutter-engine
```

The native protocol benchmark replaces the removed C++ benchmark:

```sh
cargo bench --manifest-path compositor/Cargo.toml --features wire --bench wire
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

LIBSEAT_BACKEND=logind compositor/target/release/deniald --frames 60
LIBSEAT_BACKEND=logind compositor/target/release/deniald \
  --frames 2400 --wayland
```

With the Flutter shell, omitting the finite harness limits starts the normal
session loop. It keeps running until the shell requests logout; the existing
normal-exit path then restores the captured atomic KMS state:

```sh
cargo build --release --features flutter --manifest-path compositor/Cargo.toml \
  --bin deniald

LIBSEAT_BACKEND=logind compositor/target/release/deniald \
  --wayland --flutter-bundle /path/to/denial/bundle
```

The `flutter` feature includes `kms`; a binary built with only `kms` cannot
load the Flutter bundle.

The KMS compositor starts a rootless Xwayland server and exports its dynamic
`DISPLAY` alongside `WAYLAND_DISPLAY`. Install the system `Xwayland` executable
to run X11-only applications such as Steam; the development session fails
early with a clear error when it is absent.

For the first full-session attempt on the current development workstation,
keep teardown bounded while exercising the real Flutter/Wayland path:

```sh
LIBSEAT_BACKEND=logind compositor/target/release/deniald \
  --output-config dev/denial-outputs.conf \
  --wayland --flutter-bundle dart_shell/build/elinux/x64/release/bundle \
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
resolution; otherwise it selects the fastest native mode. Unlisted outputs use
the deterministic left-to-right fallback. Command-line position assignments
override the file:

```text
# ~/.config/denial/outputs.conf
DP-5=0,0,200
DP-4=2560,0,180
```

```sh
LIBSEAT_BACKEND=logind compositor/target/release/deniald \
  --output-config ~/.config/denial/outputs.conf --frames 60
```

Dynamic-layout and hotplug regression harnesses:

```sh
LIBSEAT_BACKEND=logind compositor/target/release/deniald \
  --frames 120 --reconfigure-at-frame 60 \
  --next-output-position DP-4=0,0 \
  --next-output-position DP-5=0,1440

LIBSEAT_BACKEND=logind compositor/target/release/deniald \
  --frames 150 --wayland --simulate-hotplug-at-frame 60
```

With `--wayland`, the process advertises physical `wl_output` globals, XDG
shell, SHM and `linux-dmabuf` v4 feedback for the EGL render node.  A Vulkan
Wayland client has been validated through DP-5 removal/reconnection while its
four dma-bufs remained imported and the client kept presenting.

Measured on the current DP-4/DP-5 setup, the steady dual-output loop runs at
about 180 Hz (the slower output), with roughly 0.32 ms average render time while
the temporary software cursor uses a second GL pass.  A 2400-frame Vulkan
client run completed at 179.96 Hz before hotplug accounting; all finite runs
restored DP-5's original 60 Hz console mode and both original scanout buffers.
