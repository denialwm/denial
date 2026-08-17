# libeis support plan

Denial should treat EIS as another native input source feeding the existing
input router. It must not bypass compositor policy by injecting events directly
into `wl_keyboard`, `wl_pointer`, or Flutter.

```text
RemoteDesktop portal grant
        |
        v
per-session EIS file descriptor
        |
        v
libeis protocol and lifecycle
        |
        v
source-tagged Denial input events
        |
        +-- Flutter shell
        +-- Smithay Wayland seat / Xwayland
        `-- grabs, constraints, shortcuts, and idle policy
```

## Recommended scope

Implement support in stages:

1. Sender contexts: keyboard and relative pointer.
2. Portal authorization and `ConnectToEIS`.
3. Absolute pointer and touch regions.
4. Receiver contexts and the InputCapture portal.

RemoteDesktop uses sender contexts: the application sends input to Denial.
InputCapture is significantly larger because Denial must send captured physical
input outward, manage barriers, and decide when capture activates. The portal
specifications treat these as separate workflows:
[RemoteDesktop][remote-desktop-portal] and [InputCapture][input-capture-portal].

## 1. Refactor the input boundary first

Denial currently hard-codes `LibinputInputBackend` at both important
boundaries:

- `process_input_event()` in
  `compositor/src/bin/deniald/wayland_frontend/input.rs`;
- `InputQueue::handle()` in
  `compositor/src/bin/deniald/flutter_runtime.rs`.

Introduce an owned, backend-neutral event type:

```rust
struct InputSourceId {
    session: u64,
    device: u64,
    kind: InputSourceKind,
}

enum NativeInputEvent {
    Key {
        source: InputSourceId,
        key: u32,
        pressed: bool,
        time_usec: u64,
    },
    Motion {
        source: InputSourceId,
        delta: Point<f64, Logical>,
        time_usec: u64,
    },
    MotionAbsolute {
        source: InputSourceId,
        position: Point<f64, Logical>,
        time_usec: u64,
    },
    Button {
        source: InputSourceId,
        button: u32,
        pressed: bool,
        time_usec: u64,
    },
    Axis {
        source: InputSourceId,
        // Pixel deltas, v120 values, and stop/cancel state.
    },
    TouchDown {
        source: InputSourceId,
        slot: u32,
        position: Point<f64, Logical>,
        time_usec: u64,
    },
    TouchMotion {
        // Source, slot, position, and time.
    },
    TouchUp {
        // Source, slot, and time.
    },
    TouchCancel {
        // Source and slot.
    },
    Frame {
        source: InputSourceId,
    },
    DeviceRemoved {
        source: InputSourceId,
    },
}
```

Libinput and EIS then become adapters into this representation. The existing
routing logic remains authoritative: lock capture, Flutter/client hit-testing,
pointer constraints, grabs, focus, XKB, and idle behavior all continue through
the path documented in [Denial architecture](architecture.md#input).

Source identity is essential. State currently stored as plain keycodes, buttons,
and touch slots will collide when physical and virtual devices operate
simultaneously. Track ownership per source and emit an aggregate transition only
when the union changes. Disconnecting an EIS keyboard must release its keys
without releasing a physically held key. Touch slots need allocation per
`(connection, device, client_slot)`.

Replace `InputQueue::handle()` with explicit backend-neutral methods such as
`handle_button`, `handle_scroll`, and `handle_touch_*`.

## 2. Use the official libeis engine for production

Denial's pinned Smithay already contains a pure-Rust `backend::libei`, and
`reis 0.7.0` is already present in `compositor/Cargo.lock`. That is useful for a
prototype, but the current wrapper must not ship unchanged:

- it rejects receiver contexts;
- it discards `Frame`, `Ready`, and start/stop-emulating events;
- its device helper lacks absolute regions and mapping IDs;
- Reis describes its calloop EIS support as incomplete and experimental.

These omissions affect touch batching, device-ready ordering, disconnect
cleanup, XKB modifier synchronization, and remote-desktop coordinate mapping.

For release-quality support, link `libeis-1.0`, keep small committed Rust FFI
declarations, and wrap all handles with RAII types. The official server API
supports the preferred private-FD backend, complete client and device lifecycle,
regions, keymaps, and sender and receiver contexts. See the
[official libeis server API][libeis-server-api].

If avoiding another native dependency becomes a hard requirement, complete the
Smithay/Reis backend first. The rest of this architecture remains identical.

## 3. Model each EIS connection as a portal session

For each authorized remote-desktop session:

- create a private EIS context using the FD backend; never expose a production
  `LIBEI_SOCKET`;
- accept only sender contexts initially;
- create logical seat `seat0`;
- advertise only the capabilities the user approved;
- create keyboard and relative-pointer devices when the client binds those
  capabilities;
- advertise Denial's exact current XKB keymap;
- wait for device-ready before resuming the device;
- reset only that source on start-emulating;
- release or cancel everything owned by that source on stop-emulating, pause,
  device removal, or disconnect;
- process an EIS frame as one logical batch, issue `wl_touch.frame` when
  required, update EIS XKB modifiers, and flush Wayland clients once.

EIS events should feed the normal compositor input stack while remaining
distinguishable for access control. See the [EI protocol overview][ei-overview].

Keyboard source policy must distinguish physical and emulated input. EIS should
reach ordinary shell and application shortcuts, but must not invoke trusted
escape paths, grant permissions, or perform secure session actions merely
because it synthesized the corresponding key combination.

Pause devices and clear their state when:

- Denial locks;
- libseat becomes inactive;
- portal permission is revoked;
- the session closes;
- the EIS peer disconnects.

## 4. Add the portal backend

Production clients should receive the EIS descriptor through
`org.freedesktop.portal.RemoteDesktop.ConnectToEIS`. It may be called once after
the remote-desktop session starts. Once connected, input for that session must
flow exclusively through EIS. See the
[RemoteDesktop portal contract][remote-desktop-portal].

Keep `denial-portal` as a small D-Bus backend and keep all EIS and input state in
`deniald`. They should exchange the EIS descriptor over a dedicated
`SOCK_SEQPACKET` IPC using `SCM_RIGHTS`; do not graft descriptor passing onto the
existing line-oriented JSON control protocol.

The backend handles:

- `CreateSession`;
- `SelectDevices`;
- the user-consent prompt through the shell;
- `Start`;
- `ConnectToEIS`;
- session closure and revocation.

Packaging then adds the following entry to `denial-portals.conf`:

```ini
org.freedesktop.impl.portal.RemoteDesktop=denial
```

It must also install the `.portal`, D-Bus activation, and systemd user-service
metadata.

Full remote desktop combined with screen capture will eventually require
coordinating Denial's RemoteDesktop backend with ScreenCast so PipeWire stream
`mapping_id` values match EIS regions. The current wlr-only ScreenCast routing
does not provide that coordination automatically.

## 5. Absolute pointer and touch

Advertise one EIS region per enabled output. Normalize the EIS desktop to a
non-negative origin:

```text
eis_position    = denial_position - desktop_bounds.loc
denial_position = eis_position + desktop_bounds.loc
```

This handles Denial layouts containing negative logical coordinates. Associate
every region with the matching PipeWire stream `mapping_id` and physical scale.

Because EIS regions and keyboard keymaps are immutable after device creation,
topology or keymap changes remove and recreate the corresponding virtual
device. Relative pointer devices can remain alive across output changes.

## Completion criteria

The first production milestone is complete when:

- keyboard and relative pointer work against Flutter, Wayland, and Xwayland;
- physical and EIS devices can hold the same key or button concurrently;
- disconnect-mid-press and disconnect-mid-touch leave no stuck state;
- grabs and pointer constraints behave identically to physical input;
- lock and inactive-VT transitions pause EIS;
- unapproved capabilities never produce devices;
- no public EIS socket exists;
- official libei clients pass handshake, device lifecycle, frame, and
  synchronization tests.

The implementation order is therefore:

1. Canonical input refactor.
2. libeis sender backend.
3. Direct compatibility tests.
4. RemoteDesktop portal.
5. Absolute pointer and touch.
6. InputCapture.

[ei-overview]: https://libinput.pages.freedesktop.org/libei/
[input-capture-portal]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.InputCapture.html
[libeis-server-api]: https://libinput.pages.freedesktop.org/libei/api/group__libeis.html
[remote-desktop-portal]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html
