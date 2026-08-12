# Screenshots and screen sharing

Denial advertises `zwlr-screencopy-unstable-v1` version 3 for physical outputs
and output regions. Capture buffers can use `wl_shm` for broad screenshot-tool
compatibility or XRGB8888 DMA-BUFs for GPU-side copies. Requests complete on a
real presentation edge of the selected output, so continuous capture follows
that output's refresh cadence instead of spinning the Wayland event loop.

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

The Arch package installs the equivalent configuration. It routes the
ScreenCast and Screenshot portal interfaces to the `wlr` backend while leaving
general desktop portals with GTK. The backend turns Denial's screencopy frames
into PipeWire streams; PipeWire is intentionally not linked into the
compositor process itself.

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
