# Denial control protocol v1

Denial exposes a compositor-owned API for display settings clients and
shell-independent runtime control. It is intentionally a Denial protocol:
clients must not pretend that the compositor is Sway, Hyprland, or Niri.

## Discovery and transport

`deniald` creates a Unix stream socket at:

```text
$XDG_RUNTIME_DIR/denial/control.sock
```

It exports the absolute path as `DENIAL_SOCKET` both to applications launched
by the Flutter shell and to the systemd/D-Bus activation environments.
The socket directory and socket are mode `0700` and `0600`, respectively.

Each connection carries exactly one UTF-8 JSON request and one JSON response.
Both are terminated by `\n`; the server then closes the connection. A request
is limited to 256 KiB. Protocol integers are JSON numbers, refresh rates are
integer millihertz, and positions are integer logical pixels.

## Read the current state

Request:

```json
{"version":1,"id":1,"method":"outputs.get"}
```

Representative response:

```json
{
  "version": 1,
  "id": 1,
  "ok": true,
  "result": {
    "serial": 7,
    "capabilities": {
      "apply": true,
      "enable": true,
      "position": true,
      "mode": true,
      "scale": true,
      "transform": true,
      "adaptive_sync": true,
      "dpms": true,
      "mirror": false,
      "ten_bit": false,
      "persistent": true
    },
    "outputs": [
      {
        "name": "DP-4",
        "description": "DP-4",
        "connected": true,
        "enabled": true,
        "powered": true,
        "x": 2560,
        "y": 0,
        "logical_width": 2560,
        "logical_height": 1440,
        "physical_width_mm": 600,
        "physical_height_mm": 340,
        "scale": 1.0,
        "transform": "normal",
        "adaptive_sync": false,
        "current_mode": {
          "width": 2560,
          "height": 1440,
          "refresh_millihz": 99946,
          "preferred": false
        },
        "modes": [
          {
            "width": 2560,
            "height": 1440,
            "refresh_millihz": 199998,
            "preferred": true
          }
        ]
      }
    ]
  }
}
```

All physically connected connectors are returned, including disabled ones.
For a disabled connector, `enabled` and `powered` are false and
`current_mode` is null. Its last requested position, mode and scale remain
available for presenting a useful re-enable configuration.

`serial` changes whenever the public connector or output state changes. It is
local to the running compositor and must be treated as opaque.

## Apply a complete configuration

The client sends every connector returned by the corresponding
`outputs.get`, together with that response's `serial`:

```json
{
  "version": 1,
  "id": 2,
  "method": "outputs.apply",
  "params": {
    "serial": 7,
    "persistent": true,
    "confirmation_timeout_milliseconds": 10000,
    "outputs": [
      {
        "name": "DP-4",
        "enabled": true,
        "powered": true,
        "x": 2560,
        "y": 0,
        "mode": {
          "width": 2560,
          "height": 1440,
          "refresh_millihz": 99946
        },
        "scale": 1.0,
        "transform": "normal",
        "adaptive_sync": false
      },
      {
        "name": "DP-5",
        "enabled": true,
        "powered": true,
        "x": 0,
        "y": 0,
        "mode": {
          "width": 2560,
          "height": 1440,
          "refresh_millihz": 199998
        },
        "scale": 1.0,
        "transform": "normal",
        "adaptive_sync": false
      }
    ]
  }
}
```

A successful response has the same `result` shape as `outputs.get`, including
the new serial and the state actually applied.

When `confirmation_timeout_milliseconds` is present, it must be between 1000
and 60000. The compositor applies the candidate without committing its
persistent file and returns a `pending_confirmation` object in the snapshot:

```json
{
  "token": 42,
  "deadline_unix_milliseconds": 1786966200000
}
```

The client keeps or restores the transaction with the matching token:

```json
{"version":1,"id":8,"method":"outputs.confirm","params":{"token":42}}
{"version":1,"id":9,"method":"outputs.rollback","params":{"token":42}}
```

`outputs.confirm` commits the already prepared persistent configuration and
clears the deadline. `outputs.rollback` restores the previous runtime
configuration immediately. If neither request arrives by the deadline, the
compositor performs the same rollback autonomously. The deadline and rollback
live in the compositor rather than its Flutter client, so a topology-driven
Flutter restart or UI failure cannot disable the safety timeout. Another apply
is rejected with `confirmation_pending` until the transaction is resolved.

The request is rejected unless:

- its serial is current;
- it names every connected connector exactly once and no unknown connector;
- at least one connector remains enabled;
- every requested mode is advertised by that connector (a nominal refresh is
  matched within 1 Hz to account for DRM timing);
- scale is finite and between 0.25 and 8.0;
- a disabled connector is not requested powered on; and
- `persistent` is false, or the compositor advertises the `persistent`
  capability.

Version 1 accepts `normal`, `90`, `180`, `270`, `flipped`, `flipped-90`,
`flipped-180`, and `flipped-270`. Denial programs the primary plane's DRM
rotation property for every atlas commit. A transform unsupported by the
selected plane is rejected by the atomic `TEST_ONLY` validation and leaves the
previous display configuration active.

Mode, position, scale, enable state, and adaptive sync are staged through
Denial's topology transaction. The compositor allocates the candidate atlas,
renders it, performs KMS `TEST_ONLY`, commits all active CRTCs, waits for
vblank, publishes the Wayland topology, and installs the configuration only
after success. Failures before finalization restore the previous scanout.
DPMS changes follow that topology commit; the returned `powered` fields are
the authoritative result.

The `persistent` capability is true when `deniald` was started with
`--output-config PATH`. A request with `persistent: false` changes only the
running compositor. With `persistent: true`, Denial prepares and syncs a
replacement for that file before touching KMS, then atomically renames it over
the unchanged original only after the runtime transaction succeeds. For a
timed transaction, the rename is deferred until `outputs.confirm`; rollback
drops the prepared replacement. Denial owns this write; clients must not edit
the file themselves.

The persistent form stores position, exact mode and millihertz refresh, scale,
transform, enablement, and adaptive sync. DPMS is intentionally runtime-only.
Settings for connected outputs replace their old directives, while comments,
`system_bar`, `maximize_padding`, and settings for disconnected outputs are
preserved. New configurations use separate position, exact-mode, and scale
directives:

```text
NAME=X,Y
mode=NAME,WIDTH,HEIGHT,REFRESH_MILLIHZ
scale=NAME,SCALE
```

For example, `mode=eDP-1,1920,1080,60000` selects 1920×1080 at 60 Hz. Denial
writes and documents exact-mode refresh rates in millihertz, but accepts values
below `10000` as hertz when reading hand-written configurations. If the exact
requested refresh is unavailable, Denial uses the closest refresh advertised
for the requested resolution. The legacy combined `NAME=X,Y[,REFRESH_HZ]`
syntax remains accepted for existing configurations; its optional refresh
field is expressed in integer hertz.

Denial rejects symlinked or concurrently edited targets. If the final
filesystem commit fails after the KMS transaction has already succeeded, the
request returns `persistence_failed`; the runtime state is still published and
the client should query it again.

## Flutter UI lifecycle and recovery

UI-development methods are executed by the compositor event loop. They do not
travel through Flutter, so they remain available when a custom shell is
unusable. Every successful method returns the authoritative UI state:

```json
{"version":1,"id":3,"method":"ui.get"}
```

The result contains `active_mode`, `desired_mode`, `operation`, capability
flags, workspace and JIT-component validity, runtime generation and state
revision, optional progress, the authenticated loopback VM-service URI,
status, error, and bounded diagnostics.

UI method IDs must be nonzero and fit an unsigned 32-bit integer. The returned
state includes that value as `acknowledged_request_id`, allowing clients to
distinguish an accepted transition from an older state snapshot.

| Method | Parameters | Effect |
| --- | --- | --- |
| `ui.get` | none | Refresh and return UI runtime state |
| `ui.workspace.set` | `{"path":"/absolute/flutter/project"}` | Validate and select the source workspace |
| `ui.live.enable` | none | Replace the packaged AOT shell with the prepared JIT shell |
| `ui.live.disable` | none | Return from JIT to the packaged AOT shell |
| `ui.reload` | none | Request Dart hot reload when the native tooling client supports it |
| `ui.restart` | none | Request Dart hot restart when supported |
| `ui.build` | none | Build and activate an optimized custom shell when supported |
| `ui.restore` | none | Restore the packaged optimized shell |
| `ui.revert` | none | Restore the last working custom shell when supported |
| `ui.auto_reload.set` | `{"enabled":true}` | Configure native source watching when supported |

Runtime replacement methods acknowledge the requested transition before the
engine replacement completes. Clients which need completion semantics should
poll `ui.get` until `operation` is `idle` and `active_mode` matches the
requested mode. `denialctl` does this by default.

Unsupported actions and invalid workspaces return the `rejected` error. A
failure while starting JIT or a custom shell is represented in `ui.get`;
Denial attempts to restore `official_optimized` without ending the Wayland
session.

## Errors

Errors use this envelope:

```json
{
  "version": 1,
  "id": 2,
  "ok": false,
  "error": {
    "code": "stale_configuration",
    "message": "configuration serial 7 is stale; current serial is 8"
  }
}
```

Defined codes are `invalid_request`, `unsupported_version`,
`unknown_method`, `invalid_params`, `busy`, `timeout`, `unavailable`,
`stale_configuration`, `invalid_configuration`, `unsupported`,
`apply_failed`, `persistence_failed`, and `rejected`.

After `stale_configuration`, a client must query again and must not silently
replay edits against the new hardware state.

## `nwg-displays` backend mapping

An upstream Denial backend can use Python's standard `socket` and `json`
modules; it needs no i3 IPC dependency and should select this backend when
`DENIAL_SOCKET` is present.

| `nwg-displays` field | Denial v1 source |
| --- | --- |
| `active` | `enabled` |
| `dpms` | `powered` |
| `description` | `description` |
| `x`, `y` | `x`, `y` |
| `logical-width`, `logical-height` | `logical_width`, `logical_height` |
| `physical-width`, `physical-height` | `current_mode.width`, `.height`; use the first advertised mode while disabled |
| `transform` | `transform` |
| `scale` | `scale` |
| `scale_filter` | `None` (Denial exposes no selectable filter) |
| `refresh` | `current_mode.refresh_millihz / 1000.0` |
| `modes` | `modes`, preserving millihertz internally |
| `adaptive_sync_status` | `"enabled"` when `adaptive_sync`, otherwise `"disabled"` |
| `focused` | false; it is not used by the Denial backend |
| `mirror` | empty string; capability is false |
| `ten_bit` | false; capability is false |
| `monitor` | match `Gdk.Monitor` by logical position |

`list_outputs_activity()` maps connector names to `enabled`. The Denial apply
branch should send one `outputs.apply` transaction rather than write a Sway,
Hyprland, or Niri configuration file. Position-based GDK monitor matching,
already used by the Niri backend, avoids relying on connector enumeration
order. It should set `persistent` when the matching capability is true,
including when restoring the pre-apply snapshot after a rejected confirmation.
