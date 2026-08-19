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
    GBM/EGL rendering and Volition atomic DRM/KMS presentation
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

Impeller GLES is the default Flutter renderer. Denial's locked engine fork
connects it directly to the rotating compositor-owned FBOs, preserves atlas
damage, and keeps external client textures alive through native GPU fences.
Skia/Ganesh remains compiled into the same engine as an explicit compatibility
fallback.

Atomic presentation synchronization lives in the in-tree
`denial_core::volition` library module at `compositor/src/volition/`. Volition
owns the DRM file descriptor, reusable plane commits, and alternating KMS
lookahead lanes. Denial's output scheduler remains the caller: it chooses the
frame, retains buffer ownership through page-flip completion, and handles
Flutter, Wayland, DPMS, and screenshot policy.

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
- keyboard text from the built-in OSK returns through the native bridge;
- Rust selects one text endpoint from the Flutter editor generation, the
  focused `zwp_text_input_v3` editor, or the seat fallback. Native text-input
  editors receive Unicode through `commit_string`/`done`, while named and
  physical keys remain on the Smithay seat.
- one external input-method client may bind `zwp_input_method_v2` for the seat;
  later contenders receive `unavailable`, and its `zwp_virtual_keyboard_v1`
  companion is accepted only from that same Wayland client. Rust bridges its
  keyboard grab, loop-safe key pass-through, and editing transactions to the
  active endpoint, while candidate surfaces join the same Flutter scene and
  native input layout.

Rust also owns one live XKB configuration for that seat. The same map and
repeat metadata reach native Wayland clients and Xwayland; Flutter physical
events are projected from that XKB state and use a native Compose state and
repeat timer. `Super+Space` selects the next configured layout and
`Shift+Super+Space` selects the previous one. XKB group-switch options remain
available and publish the resulting active layout back to the shell.

The endpoint broker keeps keyboard focus, shell capture, editor activation,
and Flutter engine lifetime as separate state. Flutter is an endpoint adapter,
not a fabricated Wayland surface. The full Wayland contract is documented in
[Wayland text input v3](protocol/text-input-v3.md).

## Settings

Rust is the sole owner of the versioned, pretty-printed settings document at
`$XDG_CONFIG_HOME/denial/settings.json` (or
`$HOME/.config/denial/settings.json`). It migrates older documents, protects
native-owned sections, revision-checks every mutation, rejects concurrent
external edits, and persists through a mode-`0600` temporary file plus atomic
rename. Flutter reads and updates the shared document only through typed wire
transactions.

Keyboard settings live in the native-owned `keyboard` section:

```json
{
  "version": 9,
  "revision": 3,
  "keyboard": {
    "layouts": [
      { "layout": "us", "variant": "" },
      { "layout": "de", "variant": "nodeadkeys" }
    ],
    "options": ["compose:menu"],
    "repeatDelayMs": 450,
    "repeatRateHz": 30
  }
}
```

Rust syntax-checks and compiles a candidate keymap before it changes either
the seat or the file. A failed live install keeps the previous configuration;
a persistence conflict rolls the live seat back.

Touchpad preferences live in the native-owned `touchpad` section:

```json
{
  "touchpad": {
    "tapToClickEnabled": true,
    "naturalScrollEnabled": false
  }
}
```

Denial applies these preferences through libinput when a touchpad appears and
on every live update. The shell receives touchpad presence separately so it
only exposes the touchpad page when suitable hardware is connected.

## Platform bridge

Structured compositor traffic uses the checked-in FlatBuffers schema in
`protocol/denial.fbs`. Generated Dart and Rust code is versioned in the
repository. Small high-frequency or service commands use bounded binary
packets. The versioned settings JSON is carried only as a bounded string
inside revisioned FlatBuffers transactions; it is never an unframed channel
protocol.

The [current channels](protocol/CHANNEL_INVENTORY.md) and
[ordered wire format](protocol/WIRE_FORMAT.md) are documented alongside the
other protocol contracts.

Embedded Dart never starts a process. Application launch and one-shot shell
actions cross the native command bridge. Frequent controls use persistent
native connections rather than command-line utilities.

## External control

`deniald` exposes one mode-`0600` Unix socket below the user's runtime
directory. `denialctl` uses its versioned request/response protocol for native
status, output inspection, Flutter runtime changes, and packaged-shell
recovery. Display clients use the same transport for complete transactional
output configurations.

The socket worker never mutates compositor state. It validates and bounds each
request, queues mutations onto the compositor event loop, and returns the
authoritative result. UI lifecycle commands enter the native controller
directly, so restoring the packaged shell does not require the current Flutter
code to render or answer a platform message. See the
[control protocol](protocol/control-v1.md) and [`denialctl`](DENIALCTL.md)
reference.

## Source and build boundaries

Project-owned native code lives in `compositor/`; the shell lives in
`dart_shell/`; and the shared ABI lives in `protocol/`. Flutter and Skia
changes required by Denial live in the exact fork commits recorded by
`prebuilt/flutter-engine/SOURCE_LOCK.json`.

The canonical editable local forks are
`/mnt/exty/denial-flutter-fork-3.44.7` and
`/mnt/exty/denial-skia-fork-3.44.7`; the Flutter tree's nested Skia path
resolves to the latter. Cache-managed Flutter or Skia checkouts are build-only
projections of the immutable source lock and must never receive source edits.
CI validates or provisions the exact locked sources without inheriting a
developer checkout. Build output, verified caches, and fetched toolchains live
outside the Denial checkout when using `tools/denial-pc`.

## Invariants

1. Flutter is part of the compositor, not an overlay client.
2. One Dart scene owns shell composition across all managed outputs.
3. Rust owns unsafe handles and exact buffer lifetime.
4. Client presentation advances only with physical output progress.
5. Input routing consumes one immutable layout snapshot.
6. Embedded Dart never launches processes or hot-control CLI utilities.
7. Runtime paths never depend on another source checkout.
