# Notification hints

deniald owns `org.freedesktop.Notifications` and advertises `actions`, `body`,
`icon-static` and `persistence`. A notification stays until the user dismisses
it, the app closes it, or it is evicted. Only `transient` notifications expire;
a positive `expire_timeout` sets how long the banner stays up.

## Standard hints Denial reads

`urgency`, `category`, `desktop-entry`, `image-data`, `image-path`,
`resident`, `transient`, `suppress-sound`, `sound-name`, `sound-file`,
`action-icons`, `value` (progress), `x`, `y`.

Set `desktop-entry`. A tap runs the `default` action when there is one, and
otherwise focuses or starts the app the entry names.

## Denial hints

Other servers ignore them, so apps can send them everywhere.

| Hint | Type | Meaning |
|---|---|---|
| `x-denial-alert` | `b` | Whether this post shows a banner and wakes the screen. Without it, a new notification alerts and a replacement alerts only when its summary, body or image changed. |
| `x-denial-group` | `s` | Notifications of one app with the same value belong together. Without it, the app is the group. |
| `x-denial-group-summary` | `b` | This notification stands for its group instead of being one of its members. |
| `x-denial-time` | `x` | When it happened, in milliseconds since the epoch. Without it, arrival time. |
| `x-denial-messages` | `a(ss)` | The latest messages of a conversation as (sender, text), oldest first. Denial keeps the last 5. |
| `x-denial-clearable` | `b` | False: the user can't dismiss it and actions don't close it; it stays until the app closes it. Default true. |

Groups never cross apps: deniald scopes the group to `desktop-entry`, else
the app name, else the D-Bus sender.

## Messaging apps

- One notification per conversation, `replaces_id` on every new message.
- `x-denial-group` = the conversation, `x-denial-messages` = its last messages.
- Read receipts and edits that need no attention: `x-denial-alert` false.
- Close it with `CloseNotification` once the conversation is read.

Droidloom maps Android notifications onto the same hints: the Android group
key, the group summary flag, `when`, MessagingStyle messages, and Android's own
heads-up decision as `x-denial-alert`, and `isClearable()` as
`x-denial-clearable`.
