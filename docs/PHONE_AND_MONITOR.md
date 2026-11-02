# Phone and monitor

A phone running the mobile shell keeps acting as a phone when a monitor is
plugged in. The built-in panel (`DSI-`, `eDP-` or `LVDS-`) is the **phone**
and keeps the mobile shell. Every other display is a **desk** and runs the
desktop shell. Without a built-in panel, several displays all run the desktop
shell, as before.

## Windows

- Plugging a monitor in changes nothing on the phone.
- A new window opens on the screen last touched or clicked.
- A window follows the policy of the screen it is on. On the phone it fills
  the panel and pauses when minimized. On a desk it keeps desktop placement,
  stacking and tiling, and keeps drawing when minimized.
- To a desk: the monitor button above a phone recents card, or opening the
  app from the desk's launcher while it runs on the phone.
- To the phone: drop the window on the phone's screen while dragging it, or
  open the app from the phone while it runs on a desk.
- A window that leaves a desk remembers its place there and gets it back when
  it returns.
- Unplugging a desk moves its windows to the phone. Plugging the same
  connector back moves them back, except windows the user opened on the
  phone meanwhile.

## Input

- Touch on the panel belongs to the phone. The pointer crosses freely between
  the screens.
- Keyboard focus follows the last window used, on either screen.
- The on-screen keyboard shows only on the phone, and a text field on a desk
  never opens it.
- The shell publishes one input layout. `PhoneDeskInputComposer` joins the
  mobile layout, moved from the phone's origin into the scene, with the
  desktop layout, which leaves the phone's rectangle out. Phone regions rank
  above desk regions.

## Power and lock

- The power button turns off only the phone's panel and does not lock.
- Each screen has its own idle clock: the phone blanks after the display
  timeout since its last touch, the desk after its own.
- The idle lock timeout locks both screens; unlocking either unlocks both.
- If the desk leaves while the phone's panel is dark, the phone locks.
- The system suspends only when every screen is dark.
- Always-on display, rotation, the status bar, the Back gesture and the
  screenshot chord stay with the phone.

## Settings for the monitor

The phone's Settings app lists a Monitor page only while a monitor is plugged
in. Its settings change only the desk:

- **Scale** sets the monitor's output scale through `outputs.apply`, undone by
  itself unless kept within 15 seconds, as a refresh rate is.
- **Windows** is `layout.windowLayout`: stacking, tiling (`dwindle`) or
  scrolling. The phone always fills its panel, so the setting only reaches
  the desk.
- **Roundness** is `appearance.monitorCornerRadiusScale`, 0.5 unless set. The
  phone keeps `appearance.cornerRadiusScale`.
- **Wallpaper** writes the monitor's own entries in the wallpaper file:
  `outputs`, `outputAlignments` and `outputZooms`, keyed by connector. A
  wallpaper picked for the phone replaces the built-in panel's entries and
  `all`, and leaves every monitor's own entries alone.

The phone's part of the scene is clipped to its panel, so what it draws past
its edges, such as recents cards and apps sliding in or out, never lands on
the monitor.

## Overlays

Notification banners and volume and brightness levels show on the screen used
last.

## Wire

`MoveWindowToOutput` (window request 11) moves a client window between the
phone and a desk. The compositor ignores it without a desk, or when the window
is already on that kind of screen.
