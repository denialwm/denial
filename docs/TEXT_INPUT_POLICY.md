# Wayland software-keyboard activation

Wayland editor activation uses the ordinary text-input-v3 session on the
focused surface. A client touch grants one pending editor response; a subsequent
enable, content update, or explicit panel-show request can use it. Empty commits
do not consume it. No elapsed-time deadline applies to this response.

Focus changes (including between surfaces of one client), shell capture, shell
touches, and explicit panel-hide requests revoke authorization. An outside
shell touch must never grant authorization to the previously focused client.
Client touches do not themselves dismiss an already visible panel. The client
declares editor deactivation or requests panel hiding when appropriate.

For protocol clients, the shell activation serial advances only when an editor
response consumes touch authorization, never at touch-down. Otherwise the shell
would receive the old visible state before the client handles an unfocusing tap,
briefly reopening a manually closed panel. Empty commits and disable responses
do not advance this serial; a fresh enable, content response, or explicit show
does. Legacy terminal/Xwayland touches still activate immediately.

Repeated enables for the same active endpoint preserve panel visibility.
Disabling an editor closes its panel but preserves a pending client touch so a
disable/enable pair can switch editors within one surface. Explicit dismissal
revokes that pending touch, so late updates cannot undo dismissal.

This is a focus-scoped interaction policy, not proof that a specific touch caused
a specific editor update. Standard text-input-v3 supplies no touch serial in its
enable request. The compositor trusts the focused client to declare its editor;
arbitrary millisecond limits do not improve that causal information. A purely
programmatic activation without a pending client touch does not open the panel.

The Flutter-editor policy and legacy terminal/Xwayland fallback are unchanged.
Regression tests live in `wayland_frontend/text_input.rs` and cover authorization,
empty commits, idempotence, dismissal, surface changes, and editor transitions.

## Optional host-dismissal feedback

`compositor/protocol/denial-text-input-panel-v1.xml` defines an optional feedback
object associated with an ordinary text-input-v3 object. It was added for
Droidloom: Android needs to reset its requested IME visibility after the host
keyboard is dismissed, so another tap on the same focused editor can show it.
The contract is generic and does not alter window, focus, or key routing.

The shell sends an explicit DismissPanel intent when an open keyboard's drag
completes closed, echoing the activation serial captured at gesture start.
Automatic hides do not send it. The compositor rejects stale or duplicate
activation serials, then emits `dismissed` with that text input's current commit
serial. A shell touch may already have revoked automatic panel visibility;
that does not invalidate dismissal of the still-active matching editor.

The client must reject a stale commit serial. This event requests neither
submission nor focus loss. Clients without the optional global keep using
ordinary text-input-v3. Protocol copies in Denial and Droidloom are identical
and must be updated together when this version's contract is changed.

The user validated the matched Aston deployment on 2026-09-05: compositor
`ca32662684ae`, shell `cfa57ebed125`, preserved Impeller engine `f66112e57ae4`.
All 94 compositor tests passed. The ARM64 shell compiled successfully; the
Flutter test runner was blocked by a missing Abseil dependency in its debug
build graph. `tools/denial-aston-policy-install.py` checkpoints the installer
used for these updates; it stages a matched set and never restarts the session.
