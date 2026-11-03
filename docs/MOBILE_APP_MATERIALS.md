# Denial mobile app materials

Status: accepted (Islands, 2026-10-21; smoke islands and the light appearance
the same day; content under the groups and the keyboard without a fade, the
tab bar and the tab slide the same day).
Implemented in `denial-apps/libraries/denial-look`, `denial-look-gpui`,
Messages and Calls. This governs native phone
apps (Messages, Phone, Contacts, Settings and later ones). Desktop apps follow
[APPLICATION_MATERIALS.md](APPLICATION_MATERIALS.md). The phone shell's insets
protocol is in [MOBILE_APP_INSETS.md](MOBILE_APP_INSETS.md).

The Messages thread is the reference screen: bubbles float on the frosted
window, day labels and times sit on glass chips, one glass group at the top
holds back, avatar, name and call, and the composer field and Send are separate
islands above the gesture zone. Every other screen is built to the same rules.

## Composition contract

The window background is the user's glass tint at `glass.windowOpacity`, never
below 3/255. Denial's phone shell draws one frost of the wallpaper under the
whole window rectangle, transparent pixels included; there is no per-pixel
cutoff on mobile. Nothing readable sits directly on that backing.

Everything else on screen is one of four materials. Decide in this order and
stop at the first match:

1. **Bare on frost.** Avatars, photos, media, a progress spinner. Never text.
2. **Island.** Anything read at length or acted on in place: message bubbles,
   conversation rows, contact and setting rows, forms, the composer field,
   dial keys, dialogs, blocking states.
3. **Glass group.** Navigation and commands that stay in place: the top bar,
   the search bar, the call bar, action menus, in-call controls. The one
   exception is a tab bar, which is anchored (see Layout zones).
4. **Chip.** A short label about what is around it: day, time, section name,
   count, status, hint, notice. One line, at most about 24 characters.

Anything that fits none of these goes inside an island.

| Material | Fill | Radius | Edge | Shadow |
| --- | --- | --- | --- | --- |
| Window | Glass tint at window opacity, minimum 3/255 | Window radius R | None | None |
| Island | Smoke: glass tint at max(app-panel opacity, the island floor's alpha); accent, opaque, for own messages and primary actions; opaque raised in an opaque window | max(4, R - 8) | Floating edge, 0.75 lp (opaque raised: light appearance only, ink at 0.10) | Floating shadow, except in runs |
| Glass group | Glass tint at max(app-panel opacity, group floor) | max(4, R - 8) | Floating edge, 0.75 lp | Floating shadow |
| Chip | Glass tint at max(app-panel opacity, chip floor) | Fully round | Floating edge, 0.75 lp | None |
| Bare | None | Own shape | None | Optional floating shadow on a large avatar |

Rules that follow from the table:

- Islands are smoke (accepted 2026-10-21): the same glass tint as groups and
  chips, deep enough that the window backing and the island together tint the
  frost by at least the island floor. Its alpha is
  1 - (1 - floor) / (1 - window opacity), or the app-panel opacity if higher;
  `Look::island_fill`. The frost's colour shows through, so islands, groups and
  chips read as one material at different depths. An island is never lighter
  than its floor, whatever the sliders say.
- Islands in a run of three or more (bubbles, conversation rows, dial keys)
  drop the shadow. Twenty overlapping shadows read as dirt on the frost.
- Controls inside an island or group (toggle track, icon tile, a segmented
  choice, a plain button) get the foreground at 0.08 or nothing, so they take
  the island's tint. They never get their own glass or an opaque grey.
- A chip sits on the frost, never on an island. A label that names a set of
  islands (section, day, letter) is a chip; a label that belongs to one island
  goes inside it.
- Errors in chips use the error text color with an icon, not a red fill. The
  destructive action fill is #D2453B and appears only on a confirm button and
  the end-call button. The call fill #3E9B5B appears only on Call and Answer.
- Glass groups, text fields with their Send, and the tab bar blur what the
  app drew under them (`backdrop_blur` in Denial's GPUI fork, as Flutter's
  `BackdropFilter`), then tint it. The frost behind the window is the compositor's: deniald has no
  client blur protocol, so do not draw the wallpaper into the app. Chips are
  tint only.
- A screen never sets an opaque region. At window opacity 1.0 the backing is
  canvas, and islands still read as islands.

## Tokens

All values are logical pixels (lp) unless marked dp. Handhelds run at scale 2
for 225 ppi; 1 dp is 225/160 lp, as `dp()` in Messages computes it.

| Token | Value | Notes |
| --- | --- | --- |
| Gutter | **8** | denial-look `INSET`. Between islands, groups and the window edge. |
| Window radius R | 28 × `cornerRadiusScale` | `Look::window_radius`. 14 at the user's 0.5. |
| Island and group radius | max(4, R - 8) | `Look::group_radius`. 6 at R 14. |
| Control radius inside an island | max(4, island radius - inset) | `nested_radius`. |
| Bubble and conversation radius | max(4, R) | Messages `bubble_radius`, with a 4 lp tail corner toward the sender on the last bubble of a run. |
| Group floor | **0.30** dark, **0.50** light | Glass groups never go below it. On a phone, the App panels slider starts at this floor for the current appearance. |
| Island floor | **0.72** dark, **0.86** light | Window backing plus island glass together never tint the frost less. Keeps secondary text at 4.5:1 over white frost (dark) or black frost (light). |
| Chip floor | **0.50** dark, **0.70** light | Chips never go below it. |
| Floating shadow | black, y 6, blur 24, alpha **0.18** dark, **0.08** light | `floating::SHADOW_*`. |
| Floating edge | 0.75, foreground at **0.12** dark, **0.10** light | `floating::EDGE_*`. |
| Backdrop blur | radius **40** (two standard deviations) | `floating::BACKDROP_BLUR`. Under glass groups and text fields. |
| Touch target | 48 dp | Every tappable control. |
| Top group height | 56 dp | Starts at y 56 (status strip plus gutter). |
| Composer height | 48 dp | Field and Send are separate islands, same height. |
| Keyboard gap | **8** | `mobile::KEYBOARD_GAP`, the gutter. Between the keys and what rides on them. |
| Avatar | 46 dp in rows, 36 dp in the top group | |
| Chip text | 12 dp, foreground color | Secondary color is not allowed in chips. |

Text floors: body text sits only on islands. The island floor keeps secondary
text at 4.5:1 and foreground above 8:1 over the worst frost (white in dark,
black in light), at any window opacity. Chip and group text is the foreground color, never secondary, and
the floors above keep it readable on bright and busy wallpapers when the user
sets app panels to 0. Accent text on canvas is shifted toward the foreground
until it reaches 4.5:1.

The palettes are the desktop ones. Dark: canvas #22211F, raised #2C2B29,
control #383734, glass tint #000000, foreground #F2F1EF, secondary #BBB9B5.
Light: canvas #F7F6F3, raised #FFFFFF, control #EEECE7, glass tint #FFFFFF,
foreground #292825, secondary #625F59. Error text is #FF8A80 dark and #B3261E
light. Apps select roles; they never copy hex values.

## Layout zones

| Zone | Size | Rule |
| --- | --- | --- |
| Status strip | **48** at the top | Denial paints it with the app buffer's pixel at (5, 5), alpha included. Keep that pixel on the window backing: the 8 lp gutter does this. |
| Top group | y 56, 56 dp tall | Back, title or avatar and name, one or two actions. A screen's text field (search, the To field) takes the group's place while it is in use. On the tabs of a tabbed app (Calls) the top holds the tab's search bar, a glass group, and a round glass menu button; a tab without search shows only the button. |
| Content | from the top group's upper edge to the window's lower edge | Scrolls under the groups, the bars, the gesture zone and the keyboard. See Scrolling. |
| Tab bar | the bottom edge up: the gesture zone, then **52** dp of tabs | A tabbed app's tabs. Anchored, not floating: the window's full width, island smoke over the backdrop blur (opaque raised in an opaque window), the floating edge along its top only, no radius, no shadow. The gesture zone lies under its tabs, inside the bar. Stays put while the keyboard is up, under its glass. |
| Call bar | on the tab bar, else on the gesture zone, 56 dp | A call going on behind. A glass group. Stays put for the keyboard too. |
| Bottom zone | on the bars, else on the gesture zone | The thread's composer, the dialer's number, keys and call, the in-call controls, confirmations. Of these only the composer rides on the keyboard. |
| Gesture zone | **52** at the bottom | Messages `GESTURE_INSET`. The shell's pill and home gesture. No controls; content passes under it. |
| Side edges | | The shell's Back swipe. No edge rails (no A to Z index). |

Keyboard: a phone app lays itself out around the keyboard. It takes the
keyboard inset (`denial_keyboard_inset_v1`, `Window::handle_keyboard_inset` in
gpui-touch, see [MOBILE_APP_INSETS.md](MOBILE_APP_INSETS.md#keyboard-inset))
and the shell stops lifting its window. The window keeps its size; the app is
told the keyboard height and the shell's motion time once per show, change and
hide. An app without the inset is lifted by min(30% of view height, **368**),
and its top 368 lp leave the screen. Therefore:

- Only text fields at the bottom ride on the keys: the composer. Everything
  else stays where it is, at full opacity, under the keyboard. The keyboard is
  glass, and the shell refracts what is under it; nothing hides, fades or
  moves out of its way.
- Content keeps scrolling under the keys. Its last island can scroll a gutter
  clear of them (`mobile::content_bottom`).
- The top group stays on screen while typing. Search and the New
  conversation To field are at the top; the composer is the only bottom field.
- Results and candidates for a top field list downward from it, best match
  first.
- What rides on the keys keeps the gutter above them, so it sits
  max(keyboard height + **8**, 52) from the bottom (`mobile::bottom_inset` in
  denial-look; never computed in an app).
- When the keyboard goes away while a field has focus (dragged down, Back),
  the field lets go of the focus, so tapping it brings the keyboard back.

Back: the shell's edge swipe reaches the focused app as evdev `KEY_BACK`
(XF86Back; GPUI names the key `back`). The shell closes the keyboard, shade
and recents itself before an app sees Back. Every app binds `back` and
`escape` to one Back action, which undoes the innermost state first:

1. A dialog, action group or long-press selection closes.
2. A field mode (search) ends and the field clears.
3. The screen pops to the one it came from, with the reverse of its open
   motion.
4. On the root screen, the window closes.

The top group's back button runs the same action. Back never asks for
confirmation; a draft is kept, never discarded.

## Screens

These are the decided shapes. The reference page shows each one.

- **Conversation list.** Rows inside section islands: Pinned, Unread · N,
  Earlier (one "Conversations" island when there is only one section). The
  section name is inside its island, in accent text, uppercase, 12 dp. A row
  has the avatar, name and time on the first line, preview on the second, and
  an accent dot when unread; rows are divided by a hairline that starts after
  the avatar. Unread: bold name, preview in foreground. Top group: the title
  "Messages", Search, More and a round accent New.
- **New conversation.** A screen of its own: Back and the To field in the top
  group. Candidates list under it in one island labelled "Contacts and
  recent"; a typed number is an accent island of its own above it. "Not a
  phone number" is a chip. Picking opens the thread with the composer focused.
- **Search.** Search turns the list's top group into the search field and a
  Close button. Results list under it: message hits under a "Messages · N"
  chip, drawn as their bubble with the match in accent text and a chip with
  sender and time; then the matching conversations in an island labelled
  "Conversations · N". Tapping a hit opens the thread at that message.
- **Message actions.** Long-press lifts the bubble (scale 1.03, deeper shadow),
  dims the rest of the thread to 28%, shows a chip with the full time and
  state, and anchors an action group under the bubble: Copy, Delete, and Retry
  for a failed message. Conversations use the same pattern: Pin, Mark unread,
  Delete. The top-bar selection mode is retired.
- **Send states.** Sending: the time chip reads "Sending…". Failed: the chip
  reads "Not sent. Tap to try again" in error text with an alert icon; the
  bubble keeps its accent fill. A reason the app cannot send ("No SIM card",
  "No mobile network", ...) is a chip above the composer and Send becomes an
  inactive control island. Short notices are chips above the composer for
  1.8 s.
- **Confirmations.** An island dialog above the gesture zone with the rest
  dimmed: title, one line of consequence, Cancel (plain) and the action
  (destructive fill). No centered modal.
- **Blocking and empty states.** A state that blocks the whole screen ("The
  modem service is not running", "No messages yet") is one island under the top
  group with one action. A state that only blocks sending is a chip above the
  composer, and the draft stays. A sender that takes no replies replaces the
  composer with a chip.
- **Tabs.** Calls switches Recents, Contacts and Keypad with the anchored tab
  bar: each tab its icon over its name, the shown tab's icon on an accent
  pill, the others in secondary. Recents and Contacts have the search bar at
  the top, with the round menu button beside it; the keypad has only the
  button.
- **Scrolling top.** On a list screen whose top is a search bar or the
  list's own top group (Calls' Recents and Contacts, the conversation list
  and the archive), the top leaves with the content as it scrolls on, one to
  one, and comes back the same way as soon as it scrolls back, wherever the
  list is (`mobile::ScrollAway`). It stays while the search is in use.
- **Contacts list.** A favourites island first, then one island per initial
  letter with the letter inside it, as the list's section names are. The
  search bar at the top. No letter rail.
- **Contact detail.** Avatar bare, overlapping the top edge of the name island.
  Call, Message, Share in one glass group. Numbers, recent activity and birthday
  in islands; each number row has its own call and message buttons.
- **Dialer.** On the tab bar, from the bottom: the round green call island
  centered, with backspace as a round glass group beside it; the keys, each
  its own island in a run, the digit large and its letters under it; the
  number, large, on an island of its own, with the contact it belongs to
  under it in accent text. Above, an island of up to three suggestions: the
  contacts whose number holds the digits or whose name they spell on the
  keys' letters, and recent numbers no one has, the matching part marked. A
  tap puts a suggestion's number on the keypad; its button calls it.
- **In call.** Caller island at the top with the avatar overlapping its edge.
  Six controls in one glass group. End is a round island in the destructive
  fill. The backing stays the neutral tint; it never takes the caller's color.
- **Settings.** Section names are chips; each section is an island of rows with
  an icon tile, label, value and chevron. A detail page that changes appearance
  (Glass) is its own preview and applies values live.

## Scrolling

Content scrolls as it is, never faded:

- The scroll viewport runs from the top group's upper edge to the window's
  lower edge. Content passes under the top group, the bars, the composer, the
  gesture zone and the keyboard at full opacity. Only the gutter above the
  top group clips it, so the pixel Denial paints the status strip with stays
  on the backing.
- Content shows blurred through a group's or a field's tint (2026-10-21),
  and the keyboard, drawn by the shell, refracts it.
- Content padding: the first island sits a gutter under the top group
  (`mobile::content_top`), the last a gutter clear of the bars, the composer
  and the keyboard (`mobile::content_bottom`).
- Islands never overlap content.
- Chips scroll with the islands they label. Threads open at the bottom and
  anchor short histories to the bottom.

## Motion

Islands move as objects: they rise, drop away and travel. Chips only fade.
Glass groups stay in place and fade their contents. All durations go through
`Look::tween`, so Denial's duration scale applies and 0 means reduced motion.

| Moment | Motion | Timing |
| --- | --- | --- |
| Launch | Islands rise 18 dp and fade in, in order; chips fade with their island; groups fade in | Delay 120 ms + 45 ms per item, 380 ms, ease-out cubic |
| List to thread | Other rows scale to 0.96 and fade. The tapped island travels and reshapes into the thread's last incoming bubble; its avatar travels into the top group. Earlier bubbles rise 24 lp, nearest first. The composer islands rise 40 lp | 160 ms out, 300 ms travel, 240 ms in, 18 ms stagger, decelerate cubic-bezier(0.2, 0.8, 0.2, 1) |
| Thread to list | The same, reversed | Same |
| New message | Bubble rises 16 dp and fades in; its chip reads "Sending…", then the time | 300 ms, ease-out cubic |
| Long-press | Bubble lifts to 1.03; the rest dims; the action group fades in | 120 ms lift, 160 ms dim |
| Between tabs | The screens slide side by side in tab order, nothing fading; the tab bar's accent pill slides along; a search bar both tabs have stays | 300 ms, decelerate |
| Tabs to another screen | The tab bar slides down past the window's edge and back up on return; the call bar moves down onto the gesture zone | As List to thread |
| Keyboard | The composer rides on the keys; everything else stays, under them | The shell's motion time from the inset event |
| Read | Unread count fades out after the thread opens | 420 ms |

Reduced motion: every tween completes on its first frame, no stagger, no
travel. The end states are the same.

## Appearance and wallpapers

- Dark and Light follow Denial's application appearance. Both use the same
  four materials; only the palette, floors, shadow alpha and island edge change.
- Islands read on any wallpaper: the island floor is measured against white
  frost.
- Chips and groups rely on the floors. They are fixed, not wallpaper-aware.
  The shell does not publish frost brightness (open question 1).
- Do not claim arbitrary-wallpaper contrast validation; the floors were chosen
  on four reference wallpapers (warm gradient, bright sky, high-detail pattern,
  near-black night).

## What denial-look provides

Apps take every value from denial-look. No hardcoded colors, radii, alphas or
durations in apps.

- `palette` for dark and light, selected from the saved appearance, plus error
  text, the destructive fill and the call fill.
- `INSET` (gutter), `MIN_RADIUS`, `nested_radius`, `Look::group_radius`, and a
  bubble radius helper equal to max(4, R).
- Group and chip alpha helpers that apply the floors for the current
  appearance, and `Look::island_fill` for smoke.
- Floating edge and shadow tokens with the light-mode values, and the island
  edge for light appearance.
- Layout constants: status strip 48, gesture inset 52, touch target 48 dp,
  top group height, `dp()`, and the content padding `content_top` and
  `content_bottom`.
- Motion: `Look::tween`, `ease_out_cubic`, a decelerate curve, and a stagger
  helper (delay for item i).
- Live settings: watch `denial/settings.json` (atomic replace) and update the
  `Look` without a restart. Today `Look::load` reads once at launch.
- GPUI builders `island()`, `island_run()`, `glass_group()`, `chip()` and
  `control_fill()` so apps do not repeat fills, edges and shadows.

## Validation

Run `cargo check` and the app's tests. Verify foreground contrast against the
opaque palette surfaces, against the chip and group floors over black and
white, and against smoke islands at their floor over the worst frost. Rendered validation belongs to the user on the phones: do not capture
screenshots, launch apps for inspection or synthesize input without an explicit
request. A successful build is not visual acceptance.

## Open questions

1. Fixed floors or floors derived from frost brightness published by the shell.
2. Pins are app-local (like drafts) until dmail stores them, if it should.
3. `org.dmail.Voice1` returns NotSupported for everything. Until it is
   implemented, Calls mocks calls on screen and its call screen's top group
   says "Mock call".
