# Notifications plan

Started 2026-10-24. Goals: no double notifications, Android updates change the
existing notification, tapping opens the app, notifications group when it
makes sense.

Work goes brick by brick. Each brick lands, gets validated, then the next one
starts.

## Today

1. **deniald closes notifications on a timer.** `effective_timeout` in
   `compositor/src/bin/deniald/notification_server.rs` expires everything that
   is not persistent (4 s low, 7 s normal) with reason 1. The shell keeps the
   card but marks it inactive, and inactive cards can't be tapped or acted on
   (`invokeDefaultAction` needs `state.active`). Desktop banners rely on that
   close to disappear; mobile banners have their own 5 s timer.
2. **Droidloom posts a second copy.** On `NotificationClosed`, the host bridge
   (`droidloom/graphics/droidloom-wayland/src/notifications/mod.rs`) marks the
   record hidden and forgets its ID. The next Android update to that
   notification goes out with `replaces_id 0`: new ID, second card, new
   heads-up.
3. **Every Android post counts as new.** `NotificationBridge.put` gives each
   post a new version scoped to the session. The SDK reducer re-shows the
   banner on every `Replaced`. Progress ticks, chat edits, listener reconnects,
   Droidloom restarts and deniald restarts all pop up again.
4. **No grouping.** The Android bridge drops group summaries, no group key
   reaches deniald, the shell has no group model.
5. **Tapping doesn't raise an Android app.** deniald makes a launch token and
   emits `ActivationToken`, but the Droidloom bridge ignores it. Android starts
   the activity, droidloom-wayland asks for its own token without an input
   serial, and Denial refuses serial-less client tokens. An app that is
   already open stays behind. Android notifications without `contentIntent`
   and Linux notifications without a `default` action do nothing on tap.
6. **Smaller gaps.** Progress, large icon, MessagingStyle messages and `when`
   never leave Android. Droidloom always sends the icon name
   `application-x-executable`. Shell history keeps 100, the server 256, and
   trimming history closes nothing on the server. After a plugin reload the
   shell starts empty while deniald still holds notifications.

## Rules

1. deniald's store decides what exists. A notification lives until the user
   dismisses it, the sender closes it, or it is evicted. Only `transient`
   notifications expire. Banner lifetime belongs to the shell.
2. Every post says whether it alerts (`alert`). New notifications alert; a
   replacement alerts only when summary, body or image changed. Droidloom
   passes Android's own decision. Replays never alert.
3. One Android key keeps one Denial ID as long as deniald holds it.
4. The group key crosses the wire. Without one, the app is the group
   (`desktop-entry`, then `app_name`, then sender). Grouping is display only.
5. A tap always opens something: the default action, else focus or launch by
   `desktop-entry`.

## Bricks

### 1. Banner lifetime moves to the shell

Status: code and tests done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- deniald expires only `transient` notifications. A positive `expire_timeout`
  stays on the wire as the banner duration. Add the `persistence` capability.
- Desktop banners get their own timeout, like mobile.
- Fixes: dead taps on older cards, and the main Droidloom double (no more
  reason 1 close, so the bridge keeps the ID).
- Tests: deniald store tests (no expiry, transient still expires).

### 2. History is the active set

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- `Closed` removes the card instead of marking it inactive. History follows
  the active set, so its bound is the server's 256.
- Droidloom's `hidden` stays: other desktops (KDE, GNOME) close a timed-out
  popup with reason 1, and `hidden` keeps it from popping up again on every
  reconcile. Denial no longer sends reason 1 after brick 1.
- Tests: `dart_shell/test/state/desktop_notification_reducer_test.dart`.

### 3. `alert` on the wire

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- `alert` in `DesktopNotification` (`protocol/denial.fbs`), set by deniald
  per rule 2; hint `x-denial-alert` overrides it.
- The shell shows a banner only when `alert` is set. A quiet update keeps a
  showing banner in place with the new content, keeps its remaining time,
  doesn't mark the card unread and doesn't wake the screen.

### 4. Replays don't alert

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- deniald replays its active set, `alert=false`, when a replacement shell
  engine is ready (the same point that replays window focus and tray icons).
- Droidloom snapshots and owner changes re-post with `alert=false`.

### 5. Android's alert decision (notification ABI 2 → 3)

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet. Android side built
in the aston release.

- `NotificationBridge.java` sends `alert`: live post (not the first snapshot),
  `Ranking.isTextChanged()`, not `FLAG_ONLY_ALERT_ONCE` on an update, not
  `suppressAlertingDueToGrouping()`, not a group summary, no
  `SUPPRESSED_EFFECT_PEEK`, importance HIGH or above (decision 1). DEFAULT goes
  quietly to the shade.
- Android and host ship together; the hello checks ABI 3.

### 6. Tap always opens

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

Android side built in the aston release.

- Shell: no default action → focus the window whose app ID matches
  `desktop-entry`, else launch the entry. Close shade and banner after.
- Android: always send `default` (`contentIntent`, else
  `getLaunchIntentForPackage`).
- deniald already makes a token for `InvokeAction` too.
- Droidloom's `desktop-entry` moved to brick 9: its desktop file ID hashes the
  launcher component, which only Android knows.

### 7. Droidloom uses the host's token

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- The host bridge keeps `ActivationToken` per ID and, on `ActionInvoked`,
  hands it to `Activation` as a grant for that package.
- `Activation::request` and `mapped` use a fresh grant instead of minting a
  serial-less token.

### 8. Android content

Status: code done 2026-10-24 (ABI 3, with brick 5), not deployed or validated
yet. The shell doesn't show messages yet (brick 11).

- Progress (`value`), large icon (`image-data`), last 5 MessagingStyle
  messages (`x-denial-messages`), `when` (`x-denial-time`), `category`.

### 9. Group key on the wire

Status: code done 2026-10-24 (ABI 3, with brick 5), not deployed or validated
yet. `group_key`, `group_summary`, `time_ms` and `messages` are on the wire;
the shell doesn't use them yet (brick 10).

- Android sends summaries (flagged) and `sbn.getGroupKey()`.
- Android sends its launcher component, so the host can name the Droidloom
  desktop entry (`droidloom-<id>`) and icon.
- Hints `x-denial-group`, `x-denial-group-summary`; deniald computes the app
  fallback. `docs/protocol/NOTIFICATION_HINTS.md` lists every Denial hint for
  native apps (Messages notifier: one group per conversation, silent updates).

### 10. SDK groups view

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- Derived `groups`: newest member first, optional summary. A group of only a
  summary shows the summary. Two members stack (decision 2).
- A new alert in a group takes over that group's banner instead of queueing.
- `dismissGroupFromHistory` clears every clearable member and the summary.

### 11. Mobile group cards

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet. Messages show on
every card: the last two, all when expanded.

- Header (icon, app, count, time), newest member, up to two more lines. Tap
  expands to member cards; swipe dismisses every clearable member and the
  summary. Messaging notifications show their last messages.

### 12. Desktop center and lock screen groups

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet. The shade and the
center build rows the same way (`notification_rows.dart`). Dismissing a
group's last member also dismisses its summary.

- Same SDK view. Lock screen shows app and count, same preview privacy.
- Lock screen tap (decision 4): the card presses in and springs back, the face
  slides off as on a swipe and the PIN pad rises titled "Enter PIN to open
  <app>". The tap wins as the finger lifts, without waiting out the face's
  double tap. After unlocking, a single notification opens its app; a stacked
  group opens the shade's notification page with the group expanded.
  Cancelling the PIN forgets the tap. Expanded groups are shared state
  (`state/notification_groups.dart`).

### 13. Non-clearable notifications

Status: code done 2026-10-24, deployed on aston 2026-10-24, not validated yet.

- `clearable` on the wire (hint `x-denial-clearable`, default true): no swipe,
  Clear all skips them, a banner swipe only hides the banner, actions don't
  close them. Droidloom sends Android's `isClearable()`.

## Validation

- Rust: deniald store tests, `droidloom-wayland/src/notifications/tests.rs`.
- Dart: reducer and group tests through the `dart_shell` test wrapper;
  `tool/benchmark_notification_reducer.dart`.
- Android: `tests/notification-probe` takes the extras `title`, `group`,
  `summary`, `progress`, `alertonce`, `nointent` and `sender` (MessagingStyle)
  on `post`; repost an `id` for updates.
- Live: `moto70-test-notifications` keeps its eight; Downloads now updates
  one ID (quiet progress, then done) and the two Messages stack. The user
  validates.

## Open decisions

1. Android heads-up threshold: HIGH only, like Android. Decided 2026-10-24.
2. Group threshold: 2 members, app fallback included. Decided 2026-10-24.
3. Tap on a collapsed group: expand, like Android. Decided 2026-10-24.
4. Tap on the lock screen: asks for the PIN, then opens. Decided 2026-10-24.

## Not in this plan

Inline reply (KDE `inline-reply` + `NotificationReplied` would fit), deduping
the same app across Linux and Android, sound and vibration policy.
