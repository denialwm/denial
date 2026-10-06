# Known issues

## A GPU reset currently ends the compositor session

An AMDGPU ring timeout on 2026-09-02, attributed by the kernel to
`Endfield.exe`'s `UnityGfxDeviceW` thread, forced a full GPU reset and VRAM
loss. Mesa then aborted Denial's otherwise innocent, non-reset-aware EGL
context; Chromium and Moonlight also aborted. This implicates the game graphics
stack or driver rather than Denial, but does not isolate Proton as the cause.

Denial should use compatible reset-aware root and shared EGL contexts, detect
context loss, and preserve Wayland state while recreating its renderer, KMS
pools, and Flutter runtime. Invalid client buffers should be isolated to their
owner. This can preserve surviving applications, but cannot recover unsaved
state from applications that abort their own GPU process.

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
Xwayland applications may use an external input method's separate XIM path.
For applications launched by Denial, the compositor discovers an unambiguous
live server from Xwayland's standard `XIM_SERVERS` registrations when the user
has not explicitly selected `XMODIFIERS`. GTK input-method selection is
backend-scoped: native Wayland GTK applications automatically retain GTK's
Wayland text-input path, while Denial's Xwayland XSettings manager advertises
`Gtk/IMModule=xim` to GTK applications using X11. An explicit
`GTK_IM_MODULE` environment value still takes precedence. This covers
GTK-backed Xwayland Chromium and Electron applications without requiring a
per-application override or diverting native Wayland GTK applications from
text-input-v3. Denial does not launch, bundle, or select a Chinese or other
language engine, and its built-in keyboard fallback remains intentionally
layout-bound.

## Fcitx cannot change Denial's physical keyboard layout

Fcitx may show a **Wayland Diagnose** warning when its groups use different
default layouts. Fcitx supports compositor layout changes only on KDE and
GNOME; this warning does not indicate a failure of Denial's input-method
support.

If Denial should manage physical layouts, create
`~/.config/fcitx5/conf/wayland.conf` with:

```ini
Allow Overriding System XKB Settings=False
```

This does not disable Fcitx input methods. Denial does not write the setting
because the same Fcitx configuration is shared with other desktop sessions.
