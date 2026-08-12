# Wayland text input v3

Denial advertises `zwp_text_input_manager_v3` version 2 and implements
`zwp_text_input_v3` in the compositor. It uses a local adapter because the
Smithay helpers couple application text input and external input-method state,
while Denial's broker also serves Flutter editors.

Text-input focus follows the Smithay keyboard seat. Every object belonging to
the focused client receives `enter` and `leave`; each object has its own commit
counter and double-buffered client state, while the seat permits one active
editor. Focus changes, disable, destruction, and stale resources retire that
editor atomically. Surrounding-text offsets are validated as UTF-8 byte
boundaries and bounded to 4000 bytes. Version 2 cursor rectangles become
effective with the matching `wl_surface.commit`.

Rust owns endpoint selection. An active Flutter editor is identified by its
engine generation and editor revision. A focused native Wayland editor is
identified by its active text-input object. Xwayland and Wayland clients that
do not enable text-input use the physical seat fallback. Shell keyboard
capture is a separate state and prevents commands from leaking to a client.

The built-in keyboard sends arbitrary Unicode to a native editor with
`commit_string` followed by `done`. Named navigation keys and physical keys
remain seat events. This preserves shortcuts, grabs, repeat, and applications
which deliberately edit in response to keyboard events.

Denial exposes `zwp_input_method_manager_v2` and the companion
`zwp_virtual_keyboard_manager_v1` to ordinary session clients. The first valid
input-method object owns the seat; later contenders receive `unavailable`.
Virtual keyboards are accepted only from the Wayland client that owns that
input-method object, so an unrelated client cannot use the companion protocol
to inject keys. The virtual keyboard returns unhandled grabbed keys directly
to the focused client without re-entering the input-method grab. Activation,
bounded surrounding state, content type, serials, preedit, commit, UTF-8 byte
deletion, repeat/keymap changes, and paired key releases cross the same broker.
Candidate surfaces enter Flutter's scene as compositor UI, stay above desktop
windows, route pointer input back to the engine without stealing editor focus,
and are clamped to the caret's output.

Lock state, Flutter obscure fields, and Wayland password/PIN purposes deactivate
the external engine and hide its candidates. Stale engine serials and stale
Flutter generation/client identities cannot mutate an editor. Denial does not
launch, bundle, or configure a language engine; an engine such as Fcitx5 is
started and configured by the user session.
`show_input_panel` and `hide_input_panel` are accepted as optional hints, but
panel visibility remains shell policy.
