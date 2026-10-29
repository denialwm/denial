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
        "monitor_id": 7,
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

`monitor_id` is the stable numeric identity used by Denial's display-layout
and brightness APIs for that connector during the compositor lifetime.

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
`flipped-180`, and `flipped-270`. Flutter applies the output projection while
rendering into the connector's native, unrotated buffer. Transform-only
changes therefore do not depend on the primary plane's DRM rotation property,
do not change the modeset, and retain the existing buffer pool and modifier.

Mode, position, scale, enable state, and adaptive sync are staged through
Denial's topology transaction. If connector identities, modes, and adaptive
sync are unchanged, logical geometry is updated in place and the resident
Flutter output pools are reused. Hardware changes allocate candidate output
pools, render them, perform KMS `TEST_ONLY`, commit all active CRTCs, wait for
vblank, publish the Wayland topology, and install the configuration only after
success. Failures before finalization restore the previous scanout. DPMS
changes follow that topology commit; the returned `powered` fields are the
authoritative result.

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

## Settings application state

The standalone Flutter Settings application is an ordinary Wayland client.
It never accesses the compositor's settings files directly and does not use
the embedded Flutter engine's private platform channels. These methods run on
the compositor event loop and return authoritative state after validation and,
for mutations, after the native live update and persistent commit succeed.

| Method | Parameters | Result or effect |
| --- | --- | --- |
| `denial.version` | none | `{"version":"…","build":"…"}`: the installed release version, or the build identity for source and candidate builds, and that build identity |
| `settings.document.get` | none | Current document string and revision |
| `settings.document.apply` | `{"expected_revision":3,"document":"{...}"}` | Replace shell-owned settings and return the committed document |
| `settings.keyboard.get` | none | Layouts, XKB options, repeat settings, active layout, and revision |
| `settings.keyboard.apply` | revision plus a `keyboard` object | Compile/install XKB state and commit it atomically |
| `settings.input.get` | none | Input-device availability/preferences and read-only `input_deck` touch-output discovery |
| `settings.touchpad.apply` | revision plus a `touchpad` object | Apply touchpad preferences and commit them |
| `settings.shortcuts.get` | none | Bindings, supported actions/inputs, and revision |
| `settings.shortcuts.validate` | `shortcut` and optional `existing_shortcut` | Canonical validation result without mutation |
| `settings.shortcuts.add` | revision and `shortcut` | Add and commit a binding |
| `settings.shortcuts.update` | revision, `existing_shortcut`, and replacement | Replace and commit a binding |
| `settings.shortcuts.remove` | revision and shortcut identity | Remove and commit a binding |
| `settings.shortcuts.restore` | `{"expected_revision":3}` | Restore default bindings |

All mutations use optimistic concurrency. A stale revision returns
`conflict`; the client must read the relevant snapshot again rather than
silently overwriting a newer edit. A committed document update is also pushed
to the embedded shell so desktop policy changes take effect without coupling
the Settings process to the shell render tree. For schema 10,
`appearance.colorSchemePreference` is `preferDark`, `preferLight`, or
`noPreference`. Only the authoritative committed value is published to the
private `denial-portal` snapshot channel; an optimistic Settings preview never
changes the application portal preference.

`deniald` also watches `settings.json` for direct editor saves. A valid external
document is normalized to the next authoritative revision and enters the same
publication path, so subscribed clients receive it and any pending client
revision becomes stale. Invalid external documents remain on disk for
correction while the last known-good runtime state remains authoritative.

The Settings client does not embed shell-owned transient surfaces. To open the
desktop wallpaper workflow it requests the compositor to route the action to
the embedded shell:

```json
{"version":1,"id":12,"method":"shell.wallpaper.open"}
```

The request has no parameters. A successful response means the compositor
queued the shell action; the wallpaper selector remains rendered and owned by
the desktop shell. Shell commands are rejected while the secure session is
locked.

## Audio and brightness

System controls remain owned by Denial's persistent native PulseAudio and
brightness workers. Socket requests enqueue bounded worker commands; reads
wait for the matching worker event while compositor frame dispatch continues.

| Method | Parameters | Result or effect |
| --- | --- | --- |
| `audio.get` | none | Default sink `level` and request serial |
| `audio.set` | `{"percent":65,"request_serial":4}` | Queue a default-sink level update |
| `audio.streams.get` | none | Application stream IDs, names, levels, and mute states |
| `audio.stream.set` | `{"stream_id":12,"percent":40}` | Queue an application-stream level update |
| `brightness.get` | monitor ID and connector name | Current normalized level for one output |
| `brightness.set` | monitor ID, connector, and percent | Queue a level update for one output |
| `software_dimming.get` | `{"monitor_id":7}` | Current gamma-LUT dimming level and capability for one output |
| `software_dimming.set` | `{"monitor_id":7,"percent":35}` | Apply scanout-time dimming to one output |

Percent values are integers from 0 through 100. System-control methods are
rejected while the secure session is locked.

Software dimming multiplies the output's DRM CRTC gamma ramp, after any
external gamma-control ramp, and therefore does not modify pixels in Denial's
capture buffers. A read returns `supported: false` when the active CRTC has no
usable `GAMMA_LUT`; a set then returns `unavailable`. The setting is runtime
state and Denial restores the inherited CRTC gamma blob during shutdown.

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

`ui.get` also returns query-only `output_frame_delivery` telemetry. It is
`{"enabled": false}` by default. Starting the compositor with
`DENIAL_OUTPUT_FRAME_TRACE=1` enables a bounded history of 4096 terminal native
output generations and separate pending generations. Rows carry a unique
ready-fence-token ID, output/pool/slot and logical tick identity, raster broker
transaction, output-ready and observed GPU-fence times, queue/submission times,
physical completion and an explicit outcome. The reply supplies its column and
outcome names, monotonic clock origin and anchor sampling span, lifetime counts
and eviction count. Time columns ending in `_us` are relative to the origin;
`physical_monotonic_us` is an absolute kernel timestamp. The nominal interval
and anchor span are in nanoseconds.

Capture this optional diagnostic outside measured intervals. It performs no
GPU timing query or per-frame file write. Check history coverage and keep
pending records distinct from discarded successors; these records do not
identify every Dart FrameTiming or engine raster job. Fence times describe
observation by the main loop, and repeated KMS sequences remain ambiguous.


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

## Wallpaper status

`wallpaper.status` is read-only and returns metadata from the compositor's mapped
scene, without capturing pixels or changing wallpaper selection:

```json
{"available":true,"surfaces":[{"monitor_id":7,"app_id":"mpvpaper"}]}
```

`available: false` means scene metadata has not been published yet. With
`available: true`, an empty list means no app-managed wallpaper is mapped.
Background-layer clients and output-sized bottom-layer clients
are included; ordinary windows and bottom-layer panels are excluded. Namespace
identifies the supplying app, not a video filename. These clients may draw still
or animated content, so clients must not infer animation from this endpoint.
Settings labels them “Live / app-managed wallpaper” and labels the saved image
as a fallback. An unsupported method or failed query means unknown status, never
“static wallpaper”. Status is per monitor and Settings follows the same main
output as its saved wallpaper preview. Appearance polls every three seconds;
leaving the page disposes the subscription.

## Color correction

Displays whose EDID primaries differ from sRGB show the sRGB scene converted to
their own gamut. Screenshots and screen capture read the scene before that
conversion. `color.correction.get` returns `{"enabled":true}`;
`color.correction.set` takes `{"enabled":false}` to show every display's own
response instead, answers with the new state and repaints every output. The
switch lasts until the compositor restarts.

A desktop LUT grades the whole desktop the same way, before that correction, and
also stays out of captures. `color.lut.load` takes `{"path":"/abs/look.cube"}`:
the compositor reads an Adobe/Resolve `.cube` 3D LUT over the 0..1 domain, sizes
2 to 65. `color.lut.clear` removes it. Both, and `color.lut.get`, answer
`{"lut":{"size":33,"title":"Warm"}}` or `{"lut":null}`. Every output renders
off-screen while a LUT is loaded, so loading the first LUT or clearing it
rebuilds the output pools; replacing one LUT with another only repaints. The LUT
lasts until the compositor restarts.

### Plugin action shortcut targets

`settings.shortcuts.get` also returns `plugin_actions` (an array of
`{id,label,description,provider}` descriptors) and `action_generation`. The latter
changes independently of the saved shortcut revision when a shell publishes a
new catalog. Plugin targets use `{"type":"pluginAction","id":"package.action"}`
inside the normal binding `target`. Add/update/validate retain a valid ID even
when its provider is unavailable; unavailable targets are not dispatched.

Native `supported_actions` no longer advertises legacy `openApplications`.
Schema 11 migrates saved uses to `denial_launcher.openApplications`; new default
bindings use that plugin target. `ui status` advertises the generic bridge as
`pluginActionsV1` in `capabilities`.
