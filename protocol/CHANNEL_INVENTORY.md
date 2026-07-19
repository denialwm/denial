# Denial platform-channel inventory

All custom `denial/*` traffic is binary. Framework-owned Flutter channels are
outside this inventory.

| Channel | Direction | Encoding | Purpose |
| --- | --- | --- | --- |
| `denial/wire/to_native` | Dart → native | FlatBuffers `DENW` | Input layout, window requests, OSK keys, notification commands |
| `denial/wire/to_flutter` | Native → Dart | FlatBuffers `DENW`, fixed `DENP`, or fixed `DEND` | Window/display state, actions, cursor and drag-icon state, notifications, ordered placement |
| `denial/haptics` | Dart → native | 1 byte | Prewarm or tap through the persistent haptics socket |
| `denial/audio` | Dart → native | bounded fixed packet | Read/set default output and enumerate/control application streams |
| `denial/audio_state` | Native → Dart | 5 bytes | Level and request serial |
| `denial/audio_streams_state` | Native → Dart | bounded length-prefixed packet | Application stream identities, names, level, and mute state |
| `denial/brightness` | Dart → native | little-endian `float64` | Absolute level for the output under the cursor |
| `denial/brightness_state` | Native → Dart | monitor ID + level | Authoritative native brightness update |
| `denial/system_command` | Dart → native | bounded length-prefixed packet | Launch application, toggle OSK, take screenshot, or log out |
| imported-frame timing channels | both | fixed little-endian integers | Opt-in diagnostics only |

Structured messages are limited to 1 MiB, 4,096 windows, 8,192 input regions,
32,768 visible surfaces, and 4,096 bytes per string. Native verifies schema,
direction, version, counts, enums, identities, geometry, flags, and ordering
before use.

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
