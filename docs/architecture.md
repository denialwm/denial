# Denial architecture

Denial is a Flutter-native Wayland compositor. The native compositor is Rust;
Smithay supplies the Wayland, DRM/KMS, libinput, libseat, udev and Xwayland
foundations, while Flutter owns the shell scene that combines client surfaces
with native UI.

## Runtime shape

```text
deniald
  Rust compositor
    Smithay Wayland frontend and Xwayland
    libseat/libinput/udev session and input
    GBM/EGL and atomic DRM/KMS presentation
    window, focus, grab and buffer lifetime state
    persistent native system controls

  Rust Flutter host
    dynamic Flutter Engine ABI
    external textures and platform channels
    frame scheduling and atlas buffer ownership

  Flutter engine
    Dart shell
    one logical desktop scene
    imported Wayland surfaces as external textures
```

The Flutter engine and Dart isolate run inside `deniald`; the shell is not a
Wayland client or a second compositor. The binary loads the engine, AOT
library, ICU data and assets from one Flutter bundle.

## Ownership

Rust owns everything whose correctness depends on native resource lifetime:

- Wayland resources, windows, popups, subsurfaces, focus and grabs;
- DMA-BUF/SHM imports, EGL images, fences and client buffer release;
- physical input, pointer constraints and native shortcuts;
- output modes, page flips, hotplug transactions and KMS restoration;
- application launch, audio, brightness and other native services.

Dart owns visual and interaction policy:

- desktop and touch shell layouts;
- launcher, overview, system surfaces and notifications;
- animation, gesture interpretation and shell hit regions;
- high-level focus, close, configure, launch and control requests.

Dart receives stable numeric identities and immutable metadata. It never owns
a Wayland resource, file descriptor, EGL image, fence or KMS buffer.

## Scene and outputs

Flutter renders one desktop-wide XRGB8888 GBM atlas. Each connected CRTC scans
a distinct source rectangle from the same framebuffer, so output count does
not introduce a compositor copy. Flutter renders through one shared atlas pool
whose ownership is synchronized with the independently clocked outputs.

Topology changes are validated atomically before allocation. Atlas axes above
16,384 pixels and complete pools above 1 GiB are rejected. The compositor
captures and pins the pre-Denial KMS state before the first modeset and restores
it on normal finite or session teardown.

The current implementation requires a layout compatible with the direct atlas
path. A more general per-output fallback remains roadmap work; unsupported
layouts fail explicitly instead of silently presenting corrupt state.

## Client surfaces

Smithay owns Wayland buffer admission and protocol state. Denial imports
DMA-BUF or SHM content into EGL textures, publishes a complete ordered surface
tree to Flutter, and keeps sampled generations alive until GPU and presentation
ownership permit release. Intermediate metadata may be coalesced, but client
frame callbacks and presentation feedback remain tied to physical output
progress.

## Input

Physical events enter through Smithay's libinput backend. Dart publishes one
immutable input layout containing shell regions, client regions, ordering,
visibility and keyboard/exclusive-shell flags. Rust swaps that snapshot as one
unit.

- shell hits become Flutter pointer events;
- client hits are transformed and delivered through the Wayland seat;
- grabs, pointer constraints and drag-and-drop take precedence;
- window move and resize remain compositor operations;
- keyboard text from the built-in OSK returns through the native bridge.

## Platform bridge

Structured compositor traffic uses the checked-in FlatBuffers schema in
`protocol/denial.fbs`. Generated Dart and Rust code is versioned in the
repository. Small high-frequency or service commands use bounded binary
packets. No custom Denial channel uses JSON.

The [current channels](protocol/CHANNEL_INVENTORY.md) and
[ordered wire format](protocol/WIRE_FORMAT.md) are documented alongside the
other protocol contracts.

Embedded Dart never starts a process. Application launch and one-shot shell
actions cross the native command bridge. Frequent controls use persistent
native connections rather than command-line utilities.

## Source and build boundaries

Project-owned native code lives in `compositor/`; the shell lives in
`dart_shell/`; and the shared ABI lives in `protocol/`. Flutter Engine changes
required by Denial are retained as patches under `patches/flutter-engine/`.
Build output and fetched toolchains live outside the checkout when using
`tools/denial-pc`.

## Invariants

1. Flutter is part of the compositor, not an overlay client.
2. One Dart scene owns shell composition across all managed outputs.
3. Rust owns unsafe handles and exact buffer lifetime.
4. Client presentation advances only with physical output progress.
5. Input routing consumes one immutable layout snapshot.
6. Embedded Dart never launches processes or hot-control CLI utilities.
7. Runtime paths never depend on another source checkout.
