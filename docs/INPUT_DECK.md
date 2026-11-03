# Touch display keyboard and touchpad

The reference desktop offers **Settings → Displays → Keyboard & touchpad
display**. This is disabled by default. Enable it for a mapped touch output to
use that display as a full-screen Flutter keyboard and relative touchpad while
another powered desktop display is available. The touch output keeps its own
wallpaper, including per-output assignments and spanning wallpaper placement.

Disconnecting or disabling the last other output restores the ordinary tablet
scene through the existing output-hotplug reconciliation. The preference stays
enabled for the next connection. **Use as display** turns the preference off
immediately and keeps the other customizations; Bluetooth keyboards and mice can
then accompany the normal display. Enable the preference again in Displays.

Keyboard height, touchpad width and height, pointer speed, natural scrolling,
and CPU/GPU charts are configurable. GPU charts show only available readings.
Charts use the existing telemetry providers and subscribe only when displayed.

The panel is arranged like a laptop: a slim strip with the charts and **Use as
display**, the keyboard, and the touchpad directly below it. The keyboard keeps
laptop key proportions on a 15-unit grid and centers itself instead of
stretching keys on very wide displays; the touchpad width follows the keyboard.
The keyboard, touchpad and strip controls use the shell's panel material, so
transparency mode, blur, glass, opacity and roundness follow Appearance.

## Input behavior

- One finger moves the desktop pointer by relative motion.
- A short tap clicks; a two-finger tap right-clicks.
- Two fingers scroll, ending the finger-axis sequence when a finger lifts.
- Double tap and hold drags. The left and right click zones along the
  touchpad's lower edge hold their buttons independently of touchpad taps, so a
  resting thumb and a moving finger drag, and both zones can chord.
- Three- and four-finger swipes work across the entire input screen, including
  the keyboard, charts, controls, wallpaper and touchpad. They use the existing
  **Settings → Shortcuts** touchpad bindings and target the desktop under the
  pointer. Three-finger scrolling-layout gestures retain their continuous motion
  and end/cancel behavior.
- Keyboard contacts send balanced evdev press/release transitions. This includes
  modifiers, Super shortcuts, function/navigation keys and native repeat policy.
  Printable legends come from the active seat XKB layout and modifier state,
  including changes made with physical keyboards.

The embedded shell sends bounded commands through `denial/input_deck`. Rust
validates the selected output, excludes it from pointer travel and ordinary
application output selection, and moves its application windows onto a desktop
output. Visible source windows join the destination’s active workspace; other
windows keep their workspace numbers. Existing hotplug behavior recovers them
when the desktop output disappears. Source-screen touches preserve the
focused application. Whole-screen swipes share the touchpad recognizer; window
move/pinch/minimize/crush gestures do not apply to the input panel. Default shell
surfaces and work-area reservations follow desktop outputs while the panel is
active, retaining the saved output preferences for normal use.

The keyboard shares the OSK's native key lifecycle and the physical keyboard
router. Its presentation supplies a full desktop key set rather than translating
text through the mobile OSK's fixed character mapping. Pointer buttons share the
physical mouse router, including client activation, grabs and shell routing.
Relative motion uses the existing pointer-constraint and relative-pointer path;
finger scrolling reaches ordinary Wayland axes or Flutter trackpad events.

Cancellation, manual exit, lock, device removal, loss of the other output and
queue overflow balance panel-owned input. Native lock enforcement rejects new
deck input. The panel is inside the secure stage, below the lock surface.
The public control socket exposes discovery in `settings.input.get.input_deck`
for standalone Settings; input injection remains an embedded-shell capability.

## Whole-screen gesture arbitration

The compositor observes all contacts on the reserved output before Flutter hit
testing, so swipe detection does not depend on widget boundaries. Three or four
contacts form a candidate; all participating fingers must move in a consistent
direction before the shared touchpad recognizer can claim the sequence. Resting
keyboard chords, a stationary modifier with one moving pad finger, and ordinary
one/two-finger input continue normally. A fourth contact can promote a candidate
before recognition; after recognition, the gesture keeps its original identity.

When a swipe wins, native code cancels its Flutter contacts, releases panel-owned
keys and buttons, and stops any ordinary two-finger scrolling. Remaining contacts
stay captured until lifted. The panel acknowledges cancellation delivery through
`cancel_contact` with Flutter's touch-device ID (native slot + 1). Until those
acknowledgements arrive, delayed commands from the earlier Down events are
ignored, even if the physical swipe has already ended. Lock, hotplug, leaving
input mode and shell replacement cancel the shared gesture lifecycle too.

Ordinary keyboard keys commit a tap on release. A stationary 150 ms hold starts
an ordinary native key press, after which the configured native repeat delay and
rate apply. Modifiers and keys in an already-held modifier chord press immediately.
Moving off a key cancels its pending tap/hold; this lets a normal swipe across the
keyboard avoid typing its starting keys. Cancelling a held modifier also suppresses
its standalone tap action (such as opening the launcher on Super release).

Input already delivered by a stationary hold or an immediate modifier chord
remains delivered; swipe capture does not attempt to undo text or application
actions.

## Touch association and current limits

libinput's explicit output association takes priority. Without one, Denial
prefers an internal DSI/eDP/LVDS panel, then its existing default touch output.
Devices without trustworthy associations need a correct udev/libinput output
association, particularly when multiple external touch screens are attached.
The display selector lists mapped touch outputs; only one can be reserved at a
time. This does not invent a touchscreen capability for every connected monitor.

The initial keyboard supplies an ISO-style desktop grid with XKB legends.
Alternative geometries, language-specific extra keys, palm rejection using touch
contact area, ordinary two-finger scroll inertia and an IME candidate strip are
future extensions. Ordinary XKB compose and input-method routing are retained.

## Why compositor routing

[uinput](https://docs.kernel.org/input/uinput.html) creates kernel input devices
and sends their events back to userspace consumers. That is useful for a device
that must exist outside Denial, but introduces kernel-device access and another
round trip for this embedded UI.
[libei](https://libinput.pages.freedesktop.org/libei/) provides a distinct emulated
input channel for external clients. Denial can add that as a platform feature
independently. Its embedded Flutter shell already has a trusted native boundary,
so using the existing seat routers keeps focus, shortcuts and input lifetimes
under the compositor's control without either additional dependency.
These are compositor-seat input sources, with no new `/dev/input` device nodes;
software that bypasses the compositor and reads evdev directly needs a separate
virtual-device implementation.

## Validation

Nonvisual validation uses `tools/denial-pc compositor-test`,
`tools/denial-pc sdk-test`, Dart analysis of the Flutter SDK/reference plugin,
and the pure-Dart input-deck preference, key-lifecycle and touchpad tests. It requires no development
engine, application launch or session restart.

Hardware and visual validation belong to the user. With a compatible compositor
and shell installed, check activation with an external monitor, typing and
shortcuts in Wayland/Xwayland/Flutter applications, pointer grabs, two-finger
scrolling, held dragging, three/four-finger swipes starting on the keyboard,
charts and wallpaper (and spanning widget boundaries), stationary multi-key
chords, lock/unlock, stopping the mode, and unplugging while a
key or button is held. Check that the external bar/launcher remains usable and
the tablet returns to its ordinary scene after disconnect. No automatic visual
validation or visible input triggers are part of the agent checks.
