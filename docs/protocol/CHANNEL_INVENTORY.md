# Denial platform-channel inventory

Custom `denial/*` channels use the encodings listed below. Framework-owned
Flutter channels are outside this inventory.

| Channel | Direction | Encoding | Purpose |
| --- | --- | --- | --- |
| `denial/wire/to_native` | Dart → native | FlatBuffers `DENW` | Input layout, window requests, OSK keys, notification commands, revisioned settings requests |
| `denial/wire/to_flutter` | Native → Dart | FlatBuffers `DENW` or fixed `DENP` | Window/display state, actions, cursor state, notifications, settings state, ordered placement |
| `denial/haptics` | Dart → native | 1 byte | Prewarm or tap through the optional hapticd system D-Bus service |
| `denial/audio` | Dart → native | bounded fixed packet | Read/set default output and enumerate/control application streams |
| `denial/audio_state` | Native → Dart | 5 bytes | Level and request serial |
| `denial/audio_streams_state` | Native → Dart | bounded length-prefixed packet | Application stream identities, names, level, and mute state |
| `denial/authentication` | Dart → native | bounded `DAUT` packet | Synchronize, lock, begin, respond to, or cancel a native PAM attempt |
| `denial/authentication_state` | Native → Dart | bounded `DAUT` packet | Authoritative lock state, PAM prompts, results, retry cooldown, and advisory fingerprint feedback |
| `denial/lock_frame` | Bidirectional | UTF-8 decimal token (`StringCodec`); `sync` query | Prepare a settled lock layout while KMS remains off, then acknowledge the current wake token after layout |
| `denial/clipboard` | Dart → native → reply | bounded `DCLP` request / `DCLS` response | Search/read clipboard history and activate, pin, delete, clear, or pause it |
| `denial/clipboard_state` | Native → Dart | bounded `DCLS` snapshot | Authoritative, lock-redacted clipboard-history metadata |
| `denial/brightness` | Dart → native | little-endian `float64` | Absolute level for the output under the cursor |
| `denial/brightness_state` | Native → Dart | monitor ID + level | Authoritative native brightness update |
| `denial/idle_policy` | Dart → native | little-endian `uint64` milliseconds | Configure native idle display power-off; zero disables it |
| `denial/ui_development/control` | Dart → native | bounded versioned packet | Query or change the Flutter workspace/runtime and request development or recovery actions |
| `denial/ui_development/state` | Native → Dart | bounded versioned packet | Active/desired runtime, capabilities, operation progress, VM-service URI, errors, and source diagnostics |
| `denial/system_command` | Dart → native | bounded length-prefixed packet | Launch application, toggle OSK, take screenshot, or log out |
| `denial/window_close_complete` | Dart → native | little-endian nonzero `uint64` window ID | Release native texture leases after Flutter's close animation |

Structured messages are limited to 1 MiB, 4,096 windows, 8,192 input regions,
32,768 visible surfaces, and 4,096 bytes per string. Native verifies schema,
direction, version, counts, enums, identities, geometry, flags, and ordering
before use.

The settings request/response tables carry either a JSON shell document
(limited to 256 KiB) or a typed keyboard configuration. Requests use nonzero
revision tokens. Keyboard responses may also be unsolicited (`request_id=0`)
when the active XKB group changes. Rust remains the only process that opens
the settings file.

## Haptic feedback

The `denial/haptics` byte is `0` to prewarm or `1` for a keyboard tap.
Native uses a persistent system D-Bus connection to `org.hapticd`, object
`/org/hapticd/Haptics`, interface `org.hapticd.Haptics1`. Install and configure
hapticd separately; its default actuator handles 15 ms taps at 30% intensity.
A trusted fingerprint rejection in the current lock epoch requests two 35 ms
pulses at 70%, separated by 60 ms. The bounded worker drops stale feedback;
missing hardware or a stopped service never blocks input or authentication.

## System-command packet

The packet is at most 64 KiB and contains at most 64 arguments:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 1 | command: launch `0`, toggle keyboard `1`, screenshot `2`, logout `3` |
| 1 | 8 | optional launch request ID, little-endian |
| 9 | 4 | argument count, little-endian |
| 13 | variable | repeated `uint32 byte_length` plus UTF-8 bytes |

Each argument is non-empty, contains no NUL, and is at most 4,096 bytes. Only
launch accepts arguments or a request ID. Native starts applications without
passing the arguments through a shell; logout exits through the compositor's
normal restore and teardown path. Embedded Dart never invokes `Process.run` or
`Process.start`.

## Clipboard-history packets

Clipboard requests begin with `DCLP`, protocol version `1`, a command byte,
and a zero flags byte. Direct replies and native state publications begin with
`DCLS`, version `1`, a response-kind byte, and a status byte. Every integer is
little-endian and every string is a length-prefixed, bounded UTF-8 value.

The request commands are snapshot/search, read representation, activate,
set-pinned, delete, clear, and set-paused. Snapshot entries include stable
session ID, capture time, retained byte count, image dimensions, Wayland/X11/
Flutter origin, content kind, pinned/active flags, bounded text preview,
source application identity, and retained MIME types. Representation bytes
are returned only by an explicit read request; unsolicited state messages
carry metadata only.

Native history is limited to 100 items and 64 MiB total. Text representations
are limited to 1 MiB, image representations to 16 MiB, and a multi-
representation item to 24 MiB. Only validated UTF-8 plain text/URI lists and
bounded PNG, JPEG, or WebP images are retained. Requests are at most 4 KiB,
capture and send file descriptors are nonblocking and time-bounded, and a
locked session publishes an empty redacted snapshot. Clipboard contents are
never written to disk.

## UI-development packets

Both UI-development directions use protocol version `1`, little-endian
integers, strict packet-length equality, bounded UTF-8 strings, and zeroed
reserved fields. No request or state packet may exceed 64 KiB.

The 12-byte control header contains version, command, flags, nonzero request
ID, workspace byte length, and a reserved `uint16`. Commands are query, enable
or disable live development, set workspace, hot reload, hot restart, build and
activate optimized, restore official, revert last working, and set automatic
reload. Only set-workspace carries a payload, limited to 4,096 bytes with no
NUL. Only set-auto-reload uses its one-bit flags field.

The 40-byte state header contains active and desired runtime modes, current
operation, capability flags, optional basis-point progress, runtime
generation, state revision, acknowledged request ID, four string lengths,
diagnostic count, and a reserved `uint16`. Its strings are workspace, local
authenticated VM-service URI, status, and error. At most 64 diagnostics follow
with severity, source line/column, path length, message length, and their UTF-8
payloads.

The VM service binds to IPv4 loopback, keeps Flutter's authentication code,
and disables mDNS publication. Native also writes its URI to a mode-`0600`
file below `$XDG_RUNTIME_DIR/denial/` for same-user editor tooling, and removes
it when the live runtime ends.

### Fingerprint feedback

The `DAUT` native-to-Flutter extension kind `0x84` carries `no-match` for a
rejected fingerprint from the current lock epoch. Its argument is zero. Flutter
treats it only as transient feedback: it cannot modify the authoritative lock
state, replace a PAM prompt, or apply a password cooldown. Older shells ignore
this unknown event kind; the existing success result still unlocks them.

### Fingerprint presentation scene

`denial/fingerprint_scene` is an internal StringCodec channel carrying a JSON
scene snapshot (epoch, logical output/target rectangles, external texture ID,
black background, authenticated black-scene reveal and target fade flags). Flutter replies with the
current epoch after layout and schedules a replacement frame after native
acknowledgement. This is a rendering acknowledgement, never authentication.
The compositor's external Wayland protocol remains the privileged hardware
presentation API; fprintd and native PAM/account checks own unlock decisions.
