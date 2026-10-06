# Mobile notification presentation

Research date: 2026-09-08.

## AOSP references

Android's [mobile notification design guidance](https://developer.android.com/design/ui/mobile/guides/home-screen/notifications)
separates the small app header from the content title and body. Content imagery
can reinforce the message; actions live below the content. Heads-up notifications
briefly peek over the current activity. The drawer retains notifications, and
users can swipe a heads-up upward or dismiss a notification sideways. Android
also supports expansion and grouping; those are separate features from this
Denial change.

The inspected [AOSP StackStateAnimator revision](https://android.googlesource.com/platform/frameworks/base.git/+/ae9ca52c9da54c6253a1fba318de816fdb0f79df/packages/SystemUI/src/com/android/systemui/statusbar/notification/stack/StackStateAnimator.java)
sets heads-up entrance and exit durations to 400 ms. Its improved animation path
translates the notification from above the screen using FAST_OUT_SLOW_IN, with
the reverse curve for departure. It does not require shrinking the notification
card's layout height. AOSP implementations vary across versions and flags; this
is a reference for Denial's motion, rather than a claim of exact Android parity.

## Denial behavior

Mobile uses one top-centered heads-up slot with safe-area and status-bar
clearance. Heads-up and history use the same `MobileNotificationCard`, full
available width, and 16-pixel side gutters plus safe insets. Both start collapsed
and share tap-to-expand and action disclosure controls. A 56-pixel app icon sits
at the left of one aligned text column. Titles are bold,
body copy is regular, and all mobile notification text uses the primary foreground
color. The separate app-name header is omitted; app identity remains in semantics
and is displayed for application-only locked previews. Content artwork trails the
text, and action buttons have 48-pixel height. The card and its top
inset slide together, keeping the entire card above the screen at the beginning.
Reduced-motion preferences disable the transition.

A five-second presentation timeout or upward swipe removes only the banner.
Notification history, unread state, and available actions remain intact. A
sideways swipe requests the existing notification dismissal operation. Locked
previews retain the existing content privacy policy and disable interaction.

Persistent notifications are history-only on both mobile and desktop, including
updates to existing notifications and critical notifications. Denial identifies
them through the resident hint or an explicit zero expiration timeout. The
[freedesktop notification protocol](https://specifications.freedesktop.org/notification/latest/protocol.html)
defines zero as never expiring; minus one requests the server default. For
conflicting persistent and transient flags, the requested history-only policy
takes precedence. This suppression is Denial product policy, not a claim that
AOSP universally suppresses every ongoing notification.

The desktop banner layout and motion retain their existing configuration.
Visual acceptance belongs to the user; no live notification triggers or
screenshots are part of automated verification.

## Status-bar dropdown history

The controls panel retains its original maximum 580 logical-pixel height.
Notification history is a separate scrollable stack below the bottom handle.
The status bar, header and handle move the panel. When history fits its viewport,
an upward swipe on a notification or empty space moves the panel with the finger;
48 logical pixels of upward travel or a 500 px/s upward flick closes it. When
history overflows, vertical gestures only scroll, including at either boundary.
Expanding content automatically updates this choice. The separate bottom gap
outside the history viewport can still dismiss the panel. Sideways swipes dismiss
individual notifications. Empty-space taps close the dropdown. Clear all is aligned
right below the volume slider, inside the controls panel. There is no history
heading or empty-history label. Network and battery indicators in the header
have no extra background. Lock preview and action restrictions remain enforced.

Mobile card title/body sizes are 20/18 logical pixels, with 20-pixel content
padding, a 14-pixel gap after the left icon, and theme-scaled panel corners.
Progress and actions align with the text column. The card, backdrop, occlusion
silhouette and keyboard focus outline use the same radius. Actions use 17-pixel
labels in 48-pixel touch targets. Heads-up and history cards share these metrics.

## Material and background ownership

Base dark/light panel colors are `panelBackground` and `panelBackgroundBottom`
in `lib/src/theme/shell_color_scheme.dart`. `ShellThemeData.panelColor` and
`panelGradient` in `shell_theme.dart` resolve opacity and gradient color for
panels and notifications. Glass mode defaults to dark appearance with black backing at 17% opacity.
Light appearance uses white backing at the same configured opacity. Its separate
dark/light choice also selects the matching shell foreground palette;
one transparency slider controls backing opacity for all glass panels and cards
(83% transparency by default). Both preferences persist inside the glass settings.
Quick-settings toggle buttons are deliberately opaque. Toggle and header action
buttons keep the dark palette, including active accents, text and icon colors,
even when the surrounding glass uses light appearance. Brightness and volume tracks use the shared
transparency setting with an independent backdrop sample of the already painted
panel (glass over glass). The track foreground stays inside its backdrop color
layer so screen-edge clipping composites the glass and foreground together.
Their opaque fill indicates the value without a vertical marker. Other materials retain their separate panel/card opacity controls. Application
window opacity remains independently configured.

A black shade behind the dropdown fades linearly with panel openness from 0% to
20% opacity. It is painted before backdrop sampling and follows held drags without
a separate animation clock.

Ordinary blur uses one retained filter in screen coordinates behind the whole
shade. Its output is masked to the union of the current rounded panel/card
regions. Individual shade surfaces do not filter again. This avoids moving
per-card blur snapshots, repeated filter work and filtering notification text
into another notification or the controls panel. The theme's blur strength and
downsampling remain in use. Glass keeps per-surface optical geometry with one
shared backdrop input across the panel and history. Disabled effects add no
filter. Heads-up banners outside the shade keep their independent backdrop.

## Independent entrance and continuous exit

The horizontal entrance remains a 400 ms ease-out curve with 55 ms stagger,
capped after five delays. It rearms only after a completed closed state;
reversing a held drag never restarts it. Reduced motion skips the entrance.

With openness `p`, a row's screen Y is:
`(panelHeight + 8 + scrolledRowOffset) * p - maxVisibleRowHeight * (1 - p)`.
Row sizes and scroll extent do not change. Spacing compresses while the full-size
stack travels upward; every selected row has left the screen by zero, before
the closed shade is hidden. The panel also occludes cards passing behind it,
so its transparency does not expose their text. The horizontal clock continues
independently throughout opening, closing and drag reversal.

The viewport spans screen width, with gutters inside rows. There is no shrinking
reveal mask or side-gutter clip. Rounded occlusion silhouettes follow actual
card transforms, including sideways dismissal. The controls panel and earlier
cards are subtracted from later cards' paint and input regions; uncovered parts
remain visible. Geometry is cached between invalidations and shared by painting
and hit testing. Local shape paths and clip layers are retained. A non-zero
winding prefix path combines occluders, allowing at most one boolean subtraction
per covered row rather than a subtraction for every pair of cards.

Headless regressions cover one retained blur layer during motion, tint, theme
radius, mobile typography, clear-all location/action, exit geometry, exposed
rounded corners, scrolling and drag reversal. Execution currently stops at the
required test wrapper's canonical Flutter/source-lock mismatch. Static analysis
and ARM64 compilation are independent checks; visual acceptance remains with
the user, and no visual test events are triggered by deployment verification.

## Deploying appearance controls

The shell and standalone Settings app compile separate AOT bundles, even though
Settings imports its appearance controls from `dart_shell`. Changes to those
controls must build and deploy `settings_app` as well as the shell. A shell
SIGUSR1 refresh cannot update the running standalone Settings process. Install
its new bundle separately, preserve the GTK runner and compatible engine, and
have the user close and reopen Settings to load the updated controls.
