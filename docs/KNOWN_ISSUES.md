# Known issues

## X11 windows require Denial decorations

With Impeller blur enabled, minimizing a managed X11/Xwayland window that
bypasses Denial's server-side decorations can corrupt blur and render displaced
duplicate shadows on other windows. Normal managed X11 toplevels must therefore
keep Denial's decorations, including its rounded corners and shadows; only
popup-like and override-redirect surfaces should remain undecorated.

Denial currently mitigates the issue by ignoring client decoration opt-outs.
The underlying Impeller rendering defect remains unresolved.

## A live display-scale change can end the session

In v0.2.7, applying a display-scale change through the live output transaction
can fail while Denial recreates Flutter's direct atlas. The observed failure
reports `GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT` (`status=36054`) after publishing
the new topology, then ends the compositor session instead of restoring the
previous atlas and scale.

Until this is fixed, stop Denial before changing the `scale=NAME,SCALE` entry in
`$XDG_CONFIG_HOME/denial/outputs.conf`, then start a fresh Denial session. The
requested scale is applied normally during startup.

## Hybrid graphics lacks a cross-GPU presentation fallback

Denial can render on a GPU different from the one driving the displays only
when both devices share a renderable and scanout-capable DMA-BUF modifier. If
they do not, Denial cannot yet render on the faster GPU and copy the result into
a display-GPU buffer. It must instead render the desktop on the display GPU,
which can be a serious performance limitation when a weak integrated GPU owns
the panel and a much faster discrete GPU has no direct display connection.

Applications can still use PRIME render offload independently. Denial needs a
capability-driven GPU blit path, with an explicitly synchronized staging or CPU
copy fallback, before whole-desktop rendering can cover every hybrid topology.

## Complex text requires a text-input-aware native client

The built-in keyboard can commit arbitrary Unicode to native Wayland clients
which enable `zwp_text_input_v3`. Xwayland applications and native clients
without an active text-input session still receive the compatibility
`wl_keyboard` path, whose text fallback is limited to Denial's visual US
keymap. Complex Unicode entry is therefore unavailable through that fallback.

An externally launched Fcitx5 process can use Denial's
`zwp_input_method_v2` path and its same-client virtual-keyboard companion for
native Wayland and Flutter editors, including preedit and candidate popups.
Xwayland applications may use Fcitx's separate XIM path when the user session
configures `XMODIFIERS`. Denial does not launch, bundle, or configure a Chinese
or other language engine, and its built-in keyboard fallback remains
intentionally layout-bound.
