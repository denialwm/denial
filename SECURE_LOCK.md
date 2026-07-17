# Denial secure lock

Denial's lock is compositor state, not Flutter UI state. The process-lifetime
native authentication controller owns the locked bit and is the only component
that may clear it. Reconstructing the Flutter engine therefore reconstructs a
view of an already-locked session; it does not create a fresh unlocked session.

## Operation

The primary command path is Denial's native Hyprland IPC command:

```sh
hyprctl denial-lock lock
hyprctl denial-lock status
hyprctl -j denial-lock status
```

In the Denial session, `Super+L` invokes the same process-lifetime native
authentication controller directly. It does not spawn `hyprctl`, a shell, or
any other helper process, and remains available through client shortcut
inhibitors and compositor-owned shell surfaces.

There is deliberately no IPC `unlock` command. Unlocking requires a successful
native PAM conversation belonging to the current attempt. Late, duplicated,
cancelled, or stale responses cannot clear the lock.

The legacy `$XDG_RUNTIME_DIR/denia-lock-request` file remains an
event-triggered migration adapter. Writing `1` requests the same native lock;
writing `0` only acknowledges an already-completed native unlock and never
changes security state. `$XDG_RUNTIME_DIR/denia-lock-secure` mirrors native
state for older power-service coordination.

## Authentication

By default Denial uses the system `login` PAM service. Set
`DENIAL_PAM_SERVICE` before starting the compositor to select a dedicated PAM
stack; accepted service names contain only ASCII letters, digits, `_`, and `-`
and are limited to 64 bytes. A configured PAM stack may combine password,
fingerprint, smart-card, or other system modules without giving Dart direct
access to those backends.

PAM runs on one bounded worker, never on the compositor loop. Prompts cross a
strict bounded native protocol. Credentials are transferred directly into a
move-only native buffer, scrubbed after use, never logged, and rejected when
their attempt or prompt identity is stale. Failures use an exponential retry
delay starting at 750 ms and capped at 30 seconds.

If PAM development files were unavailable at build time, Denial stays locked
and presents authentication as unavailable. It never substitutes a local or
gesture-only unlock.

## Locked-session boundary

While native state is locked, the compositor routes physical keyboard,
pointer, touch, stylus, tablet-pad, wheel, and trackpad-gesture input only to
the lock shell or swallows it if Flutter is unavailable. The check precedes
client focus, keybindings, grabs, constraints, and compositor plugin input
events. Existing captures and drag operations are cancelled at lock entry.

Wayland and XWayland clipboard receives, primary selection, drag-and-drop,
client window commands, system-control messages, notification actions, and
screencopy are denied while locked. All active outputs render the lock scene;
new outputs enter the same native lock state immediately. Notification content
follows the configured lock-preview policy, while application surfaces and
other shell panels remain below the opaque lock scene.

The lock UI supports PAM information/error prompts, obscured and visible
responses, hardware keyboard entry, a built-in on-screen keyboard,
cancellation, retry feedback, reduced motion, text scaling, and one
authentication surface on the configured main output. Every other output is
still fully covered.
