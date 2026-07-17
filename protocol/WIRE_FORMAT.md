# Denial wire format

Protocol version 1 uses FlatBuffers 25.9.23 for structured messages. The root
is `Denial.Wire.Envelope` with file identifier `DENW`. Generated code and
the C++ runtime headers are committed, so normal builds need neither network
access nor `flatc`.

Every structured envelope has a nonzero sequence number. Native verifies the
FlatBuffer, direction, version, size/count limits, enums, flags, identities,
strings, geometry, request rules, and topmost-first input-window ordering
before it copies callback-owned bytes. The retained input layout is an
immutable owned buffer swapped as one unit.

Input-layout rectangles accept every finite, strictly positive width and
height. In particular, shell-region subtraction can legitimately produce
strips narrower than one logical pixel; rejecting one would discard the whole
atomic layout and leave native hit testing on an obsolete snapshot. Configure
requests retain their separate 64-pixel minimum, and fixed placement packets
retain their one-pixel minimum.

## Fixed window-placement packet

On the ordered `denial/wire/to_flutter` stream, a message beginning with
`DENP` carries exactly 80 bytes in little-endian order. Structured messages on
the same stream retain the FlatBuffers `DENW` file identifier. Keeping both
formats on one channel preserves the ordering of placement, activation,
snapshots, actions, and cursor state from the pre-migration bridge.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `DENP` |
| 4 | 2 | protocol version (`1`) |
| 6 | 2 | message kind (`2`, window placement) |
| 8 | 4 | exact packet length (`80`) |
| 12 | 8 | sequence number |
| 20 | 8 | unsigned window ID |
| 28 | 8 | signed monitor ID |
| 36 | 8 | signed workspace ID |
| 44 | 1 | phase: begin `0`, update `1`, end `2` |
| 45 | 1 | change: move `0`, resize `1` |
| 46 | 2 | reserved, must be zero |
| 48 | 8 | logical x (`float64`) |
| 56 | 8 | logical y (`float64`) |
| 64 | 8 | logical width (`float64`) |
| 72 | 8 | logical height (`float64`) |

Readers reject a wrong magic, version, kind, length, reserved value, zero
window ID, invalid monitor/workspace ownership, unknown enum, non-finite
number, or width/height below 1. Begin and end are
never coalesced. Update packets may be coalesced later only if measurement
shows that it helps and behavior tests still pass.

## Fixed drag-icon packet

On the same ordered native-to-Dart stream, a message beginning with `DEND`
carries exactly 128 bytes in little-endian order. It publishes the transient
Wayland drag-icon surface separately from window snapshots, because a drag
icon has no logical window owner. While drag-and-drop is active, native also
publishes `CursorPosition` messages so Flutter can place the icon at the
current software-cursor position plus the surface offset.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `DEND` |
| 4 | 2 | protocol version (`1`) |
| 6 | 2 | message kind (`3`, drag icon) |
| 8 | 4 | exact packet length (`128`) |
| 12 | 8 | sequence number |
| 20 | 4 | flags; bit 0 means active, all other bits must be zero |
| 24 | 4 | reserved, must be zero |
| 28 | 8 | unsigned wl_surface ID |
| 36 | 8 | positive Flutter external-texture ID |
| 44 | 4 | buffer width |
| 48 | 4 | buffer height |
| 52 | 4 | Wayland buffer transform (`0` through `7`) |
| 56 | 4 | surface scale in units of 1/120 |
| 60 | 4 | reserved, must be zero |
| 64 | 8 | logical x offset from the pointer (`float64`) |
| 72 | 8 | logical y offset from the pointer (`float64`) |
| 80 | 8 | logical surface width (`float64`) |
| 88 | 8 | logical surface height (`float64`) |
| 96 | 8 | texture-source x (`float64`) |
| 104 | 8 | texture-source y (`float64`) |
| 112 | 8 | texture-source width (`float64`) |
| 120 | 8 | texture-source height (`float64`) |

An inactive packet clears the icon; fields after the flags are ignored. An
active packet requires nonzero identities and dimensions, finite geometry, a
positive scale and source extent, and a source rectangle contained by the
buffer. Dart rejects duplicate or decreasing drag-icon sequence numbers.
