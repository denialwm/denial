# Denial architecture

Denial is a Flutter-native Wayland compositor. The native compositor is Rust;
Smithay supplies the Wayland, DRM/KMS, libinput, libseat and udev foundations,
plus an optional Xwayland integration. Flutter owns the shell scene that
combines client surfaces with native UI.

## Runtime shape

```text
deniald
  Rust compositor
    Smithay Wayland frontend and optional Xwayland
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

denial-portal
  D-Bus-activated Settings portal backend
  read-only cache of committed appearance state
  no settings-file access and no compositor event-loop work
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

Denial's Flutter engine is a Slimpeller build: it runs Impeller GLES, while
Skia's Ganesh and Graphite renderers are disabled at engine-generation time.
The locked engine fork connects Impeller directly to the rotating
compositor-owned FBOs, preserves atlas damage, and keeps external client
textures alive through native GPU fences.

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
progress. Presentation feedback is captured with each published client buffer,
carried with the texture generation Flutter actually samples, and retained by
that rendered output through KMS completion. A later surface commit cannot be
acknowledged by an older queued desktop frame. Feedback shared across outputs
is consumed once by the first completed presentation.

The Flutter path publishes physical Wayland output enter/leave events when a
window is mapped, moved, resized or unmapped. Clients can therefore follow the
monitor's refresh rate without a whole-desktop membership sweep each frame.

Clients describe their pixels with `wp_color_management_v1` parametric image
descriptions and `wp_color_representation_v1` alpha modes; ICC profiles are not
accepted. The scene uses sRGB primaries and gamma 2.2, with SDR reference white
at 1.0, and outputs and surface feedback advertise exactly that, so a client
that renders in it costs nothing extra. Any other surface is converted once
per committed buffer: decoded with its transfer function, anchored at its
reference white, moved to sRGB primaries with Bradford adaptation, then tone
mapped (perceptual intent) or clipped (relative intent) and encoded again. The
deprecated `srgb` transfer function is read as gamma 2.2, which is what sRGB
displays show; `compound_power_2_4` keeps its piecewise curve.

A display whose EDID offers PQ can show HDR (`denialctl color hdr OUTPUT on
[WHITE]`). Its connector then receives BT.2020 colorimetry and HDR static
metadata with the display's own primaries and luminance, and its scene is half
float. The scene becomes extended: SDR white stays 1.0 and highlights reach
the display's peak over the chosen SDR white, so tagged HDR content is mapped
to that headroom instead of SDR. Impeller's layers and filters turn half float
with it (`--denial-float-color`), and the copy to scanout encodes BT.2100 PQ.
That output advertises BT.2020 and PQ, with the SDR white as reference
luminance. Some displays show a PQ signal stated as BT.2020 with sRGB primaries;
`srgb` after the white sends them sRGB values, and the output advertises sRGB
and PQ. The connector's
previous colorimetry and metadata return when Denial exits.

Synchronized surface trees preserve per-surface `wp_alpha_modifier_v1` state
and all eight Wayland buffer orientations. Opacity changes publish with the
parent transaction even when the child keeps its buffer. Flutter applies
orientation after buffer-coordinate cropping and swaps layout dimensions for
quarter turns. Droidloom can therefore supply original Android layers as
ordinary subsurfaces instead of flattening every supported task in Android.

## Input

Physical events enter through Smithay's libinput backend. Dart publishes one
immutable input layout containing shell regions, client regions, ordering,
visibility and keyboard/exclusive-shell flags. Rust swaps that snapshot as one
unit.

Desktop touchscreen swipes use the same native recognition, configurable
shortcut bindings, and release lifecycle as touchpad swipes. Three fingers up
open the overview; three fingers left or right navigate windows (continuously
in the scrolling layout when bound to the window switcher). Four fingers left
or up select the next workspace; right or down select the previous workspace.
These are the default bindings and can be remapped in Settings. Contacts may
span tiled windows and desktop background, including an empty desktop. Shortcut
actions target the output where the swipe started rather than the mouse output.
Mobile mode, the lock screen, exclusive shell overlays and the software keyboard
retain their own input. One-finger corner movement, two-finger resizing, and
four-finger inward window closing remain separate window gestures; translating
four fingers toward a window's center does not count as closing it.

- shell hits become Flutter pointer events;
- client hits are transformed and delivered through the Wayland seat;
- clients that bind `zwp_input_timestamps_manager_v1` receive libinput's
  microsecond time before each key, pointer motion, button and axis, and touch
  down, motion and up; events Denial makes itself carry the current monotonic
  time at millisecond precision;
- graphics tablets are advertised through `zwp_tablet_manager_v2`; tool
  proximity, motion, pressure, distance, tilt, rotation, wheel, tip and button
  events use the same published client hit-test. An explicit libinput output
  association wins; otherwise the tablet maps to the output under the pointer
  for that proximity sequence;
- grabs, pointer constraints and drag-and-drop take precedence;
- window move and resize remain compositor operations;
- keyboard text from the built-in OSK returns through the native bridge;
- Rust selects one text endpoint from the Flutter editor generation, the
  focused `zwp_text_input_v3` editor, or the seat fallback. Native text-input
  editors receive Unicode through `commit_string`/`done`, while named and
  physical keys remain on the Smithay seat.
- one external input-method client may bind `zwp_input_method_v2` for the seat;
  later contenders receive `unavailable`, and its `zwp_virtual_keyboard_v1`
  companion is accepted only from that same Wayland client. Its keyboard grab
  and loop-safe key pass-through stay on the Smithay seat, but the grab routes
  keys before Smithay's single keyboard-grab slot so that XDG popup grabs can
  coexist with an active input method. Flutter participates
  as a real keyboard focus target alongside Wayland and Xwayland, while editing
  transactions use the active text endpoint. Candidate surfaces join the same
  Flutter scene and native input layout.

Rust also owns one live XKB configuration for that seat. The same map and
repeat metadata reach native Wayland clients and Xwayland; Flutter physical
events are projected from that XKB state and use a native Compose state and
repeat timer. `Super+Space` selects the next configured layout and
`Shift+Super+Space` selects the previous one. XKB group-switch options remain
available and publish the resulting active layout back to the shell.

The endpoint broker keeps keyboard focus, shell capture, editor activation,
and Flutter engine lifetime as separate state. Flutter is a compositor-owned
seat focus target and text endpoint adapter, not a fabricated Wayland surface.
The full Wayland contract is documented in [Wayland text input
v3](protocol/text-input-v3.md).

## Settings

Rust is the persistence authority for the versioned, pretty-printed settings
document at `$XDG_CONFIG_HOME/denial/settings.json` (or
`$HOME/.config/denial/settings.json`). It migrates older documents, protects
native-owned sections, revision-checks every mutation, and persists through a
mode-`0600` temporary file plus atomic rename. It watches the containing
directory so editors that replace the file atomically are supported. A valid
external edit is assigned the next authoritative revision, applied to native
runtime state, and published like a Settings application change. Invalid edits
remain on disk while the last known-good configuration stays active; deleting
the file restores and recreates the defaults.

Settings runs as a separate Flutter Wayland process (`denial-settings`). It
owns only its application widget tree and talks to `deniald` through control
protocol v1 for settings, outputs, keyboard, touchpad, shortcuts, audio,
brightness, and UI-development state. It therefore has its own UI/raster
threads and cannot add build, layout, paint, or raster work to the compositor's
desktop frame. The embedded shell receives committed document notifications
and remains responsible for rendering desktop policy, but it does not host the
Settings window. Settings launch actions always target the standalone Linux
application; there is no embedded Settings registration or environment fallback.

Appearance intent lives beside the other shell-owned appearance settings. The
same committed value selects Denial's semantic light/dark palette and is
published to ordinary applications through the desktop Settings portal:

```json
{
  "version": 10,
  "appearance": {
    "colorSchemePreference": "preferDark"
  }
}
```

`preferDark` and `preferLight` map to portal values 1 and 2. `noPreference`
maps to 0 while Denial itself retains its canonical dark fallback, because a
rendered shell always needs a concrete palette. Fresh and migrated documents
use `preferDark`, preserving the established shell and giving applications an
explicit dark preference.

The Flutter scene resolves all brightness-sensitive colors through
`ShellThemeData`; curated neutral light and dark palettes share the same
brightness-independent geometry, motion, media, and telemetry tokens. Accent
seeds are normalized into contrast-safe roles separately for each brightness.
Content-bearing translucent panels enforce a palette-specific backing floor,
so the user-controlled glass opacity cannot make semantic foregrounds
illegible over an extreme wallpaper.

Scrolling-layout swaps preserve each window's strip size by default when both
windows occupy single-window columns in the same workspace and output. This
applies to keyboard swaps and drag swaps (including previews): widths follow
the windows on horizontal strips, and heights follow them on vertical strips.
Split columns and swaps across workspaces or outputs retain their slot sizes.
Disable **Keep window sizes when swapping** in Layout settings, or set
`layout.scrollingLayoutPreserveSwapSizes` to `false` in `settings.json`, to
retain slot sizes for every swap. Dwindle swaps are unaffected.

Keyboard settings live in the native-owned `keyboard` section:

```json
{
  "version": 10,
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
    "naturalScrollEnabled": false,
    "scrollSpeedFactor": 1.0,
    "scrollingLayoutSwipeSpeedFactor": 1.0
  }
}
```

Denial applies the device preferences through libinput when a touchpad appears
and on every live update. The scrolling-layout swipe factor instead scales only
the compositor-owned continuous three-finger gesture, including its release
projection; it does not affect two-finger content scrolling or shortcut swipes.
The shell receives touchpad presence separately so controls are disabled when
no suitable hardware is connected.

## Desktop portal

`denial-portal` owns
`org.freedesktop.impl.portal.desktop.denial` and implements
`org.freedesktop.impl.portal.Settings` and
`org.freedesktop.impl.portal.Access` at
`/org/freedesktop/portal/desktop`. Its authoritative appearance keys are
`org.freedesktop.appearance/color-scheme` and `accent-color`; unknown keys
return the standard portal `NotFound` error. Portal routing selects
`denial;gtk` for Settings, so GTK remains the fallback for namespaces Denial
does not own.

Access asks the user whether an app may have something and returns the
answer; callers keep it. Each request starts the Polkit dialog bundle in its
access mode as a centered overlay, over a private socket described in
`compositor/denial-portal/src/access.rs`. A boolean choice named `remember`
becomes once-or-always buttons for both answers: "Always allow", "Allow once",
"Never allow" and "Decline once". Its value is reported with a denial too,
where `true` means "never". The request handle exports
`org.freedesktop.impl.portal.Request`, whose `Close` withdraws the dialog.

### Keyboard shortcuts inhibition

deniald serves `zwp_keyboard_shortcuts_inhibit_manager_v1`. An inhibitor is
active only while its surface has keyboard focus and its app is allowed. The
first time an app asks, deniald calls Access off the compositor thread. The
portal permission store keeps each app's answer in table `denial`, entry
`shortcuts-inhibit`, by app ID: `yes` for "Always allow", `no` for "Never
allow", and `ask` for an app that was asked. "Allow once" and "Decline once"
last while the app stays connected. Settings > Permissions lists the asked apps
and changes their stored answers; deniald follows the store's `Changed` signal
and asks again an app whose stored answer changed. While an inhibitor is
active, keys go to the app even when they would trigger a Denial shortcut,
except the pointer release shortcut, VT switching, the emergency exit and the
volume and brightness keys. The shortcut engine still observes every key, and
each release goes where its press went. The pointer release shortcut also
deactivates the inhibitor until the app is focused again.

The compositor publishes complete, revisioned `DesktopThemeSnapshot` records
over a mode-`0600`, same-user `SOCK_SEQPACKET` endpoint at
`$XDG_RUNTIME_DIR/denial/portal.sock`. This is a private bounded protocol, not
the public control socket. The compositor's event loop only replaces a cached
snapshot and wakes a worker; it never waits for D-Bus or the helper. The
embedded Flutter shell is the sole source of resolved accent state because it
owns wallpaper extraction. The portal worker atomically caches the last
resolved accent under `$XDG_STATE_HOME/denial`, avoiding a fallback-color flash
on restart without adding frame-loop I/O. The helper connects and receives its
initial snapshot before claiming its bus name, ignores stale revisions, and
emits `SettingChanged` only for values that changed. It exits when `deniald`
disconnects.

Neither Flutter nor `denial-portal` reads or writes the settings file. That
keeps validation, migration, persistence, effective brightness, and portal
publication under one native settings authority.

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
8. Portal state is published only after a settings commit and never inferred
   from an optimistic Flutter preview.
