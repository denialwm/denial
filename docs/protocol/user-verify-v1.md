# PIN and password sheet for clients

`compositor/protocol/denial-user-verify-v1.xml` lets a client ask the session
user for their screen lock, the way an Android app asks to confirm the device
credential. Droidloom's device broker uses it for Android's credential prompt.

Denial draws the sheet and judges nothing. What the user types goes to the
asking client alone; the client has it checked by something that holds the
credential (for Droidloom, its root supervisor checks the PIN with the
gatekeeper provider and the password with PAM) and answers.

- `verify(id, app, title, description, credentials)` opens the sheet.
  `credentials` is a mask of `pin` and `password`. The PIN is offered only
  when the user has a PIN; with neither left, the request ends at once with
  `cancelled`. A newer request, from any client, ends the older with
  `cancelled`.
- `credential(kind, secret)` carries what the user typed, each time they
  submit.
- `rejected(retry_ms)` says it did not prove the user. The sheet shakes and
  asks again, after `retry_ms` when it is not zero.
- `accepted` closes the sheet. Destroying the verification closes it too.
- `cancelled` says the user closed the sheet, or a newer request took it.

While the session is locked the sheet waits, hidden; it shows again after the
unlock. The global is visible to root and to the user the session runs as.

The shell's side is `denial/user_verification`, little-endian records. To the
shell: `1 id:u32 pin_length:u8 password:u8` then app, title and description,
each a `u16` length and UTF-8, shows the sheet (`pin_length` 0: password
only); `2 id:u32 retry_ms:u32` asks again; `3 id:u32 accepted:u8` closes it.
From the shell: `1 id:u32 kind:u8 secret` is what the user typed (kind 1 PIN,
2 password), `2 id:u32` the user cancelled, `3` asks for the sheet showing,
after the shell starts. deniald wipes each record from the shell once handled.
