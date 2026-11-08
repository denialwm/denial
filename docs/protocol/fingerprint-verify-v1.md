# Fingerprint verification for clients

`compositor/protocol/denial-fingerprint-verify-v1.xml` lets a client ask for
the session user's fingerprint, the way an Android app asks for its biometric
prompt. Droidloom's device broker uses it for Android's fingerprint HAL.

The client draws nothing. Denial's authentication worker serves the request
with the same fprintd path, panel lighting and rejection haptic as the lock
screen, and the shell marks the sensor with the same `FingerprintMark` it
shows on the lock screen and the ambient display.

- `verify` starts a verification. A newer one, from any client, ends the
  older with `done(cancelled)`.
- `ready` is sent each time the reader arms, `rejected` after a finger that
  did not match; the reader then listens again.
- `done(match)` ends it after a match that passed PAM account validation.
  `done(unavailable)` ends it when the reader fails before it listens, or
  when deniald runs without authentication.
- Destroying the verification stops the reader and removes the mark.

While the session is locked, the reader serves the lock screen and a pending
verification waits; it continues after the unlock. A match is never an
unlock, and the client learns nothing but the result.

The global is visible to root and to the user the session runs as, the same
users fprintd's Polkit rule lets verify. The worker serves a client only when
fingerprint unlock is on and a PIN exists, as for the lock screen.

deniald publishes `"wanted": true` in the credential event's fingerprint
payload while the reader serves the lock screen or a client; the shell draws
the mark from it.
