# Screenshots and screen sharing

Denial advertises `ext-output-image-capture-source-v1` and
`ext-foreign-toplevel-image-capture-source-v1` together with
`ext-image-copy-capture-v1`. The matching `ext-foreign-toplevel-list-v1`
global enumerates mapped native Wayland and managed X11 toplevels and publishes
their title and application ID. Denial also retains
`zwlr-screencopy-unstable-v1` version 3 for older direct clients and explicit
output-region capture.

All capture sources support `wl_shm` and XRGB8888 DMA-BUFs. Output requests
complete on a real presentation edge of the selected output, so continuous
output capture follows that output's refresh cadence instead of spinning the
Wayland event loop. A foreign-toplevel request is rendered into an isolated
target from that toplevel's surface tree, so its pixels do not depend on
occlusion or its position within the composed desktop. Buffer constraints are
republished when the toplevel size or effective output scale changes, and an
unmapped toplevel closes its foreign handle and stops its capture sessions.

Denial reconstructs the capture atlas in logical desktop orientation. Native
scanout buffers are sampled with their `wl_output.transform` exactly once.
`ext-image-copy-capture-v1` buffers advertise normal orientation, while legacy
`zwlr-screencopy-unstable-v1` buffers retain the output's native pixel axes as
required by clients that combine the frame with `wl_output.transform`. The
built-in region selector and direct capture clients therefore both produce
upright results for normal, rotated, and reflected outputs.

## Direct capture

Tools such as `grim` and `wf-recorder` can connect directly to the Denial
Wayland display. Full-output and explicit-coordinate `grim` captures work.

Interactive `slurp`-based region selection still requires layer-shell support,
which Denial does not currently advertise.

## Desktop portals

Sandboxed applications, browsers, and OBS use PipeWire through a desktop
portal. The session requires PipeWire, `xdg-desktop-portal`,
`xdg-desktop-portal-gtk`,
[`xdg-desktop-portal-wlr`](https://github.com/emersion/xdg-desktop-portal-wlr),
and `zenity` for source selection.

For a development session, install or refresh the portal routing with:

```sh
tools/denial-pc install-session
```

The first-party packages install the equivalent configuration. It routes the
ScreenCast and Screenshot portal interfaces to the `wlr` backend while leaving
general desktop portals with GTK. Current `xdg-desktop-portal-wlr` versions
prefer Denial's `ext-image-copy-capture-v1` path and retain the legacy protocol
as a compatibility fallback. The backend turns captured frames into PipeWire
streams; PipeWire is intentionally not linked into the compositor process
itself.

At its first ready frame, Denial activates the packaged
`denial-session.target`, which binds the standard systemd
`graphical-session.target`. Portal activation is deliberately gated on that
ready point so a backend never inherits an unset or stale Wayland socket.

Because the default `xdg-desktop-portal-wlr` chooser starts `slurp`, Denial
provides a Zenity chooser instead. Zenity uses a regular xdg-shell window and
returns the monitor selected by the user without depending on layer-shell.

## Current limitations

- Interactive portal Screenshot and color-picker regions require layer-shell
  and are not yet available.
- The Flutter shell currently paints its software cursor into the shared
  atlas, so captured frames include that cursor even when a client does not
  request a cursor overlay.
- Foreign-toplevel capture contains the client-owned toplevel surface tree,
  without Flutter-owned server decorations or the shell cursor.
