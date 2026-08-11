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
