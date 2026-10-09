# Denial pet protocol v1

`denial-pet-v1` (`compositor/protocol/denial-pet-v1.xml`) lets a layer
surface become a desktop pet. The user can drop a pet on a window's edge or
corner, and the window then carries it: the pet moves, hides and shows with
the window until the window lets it go.

Nothing in it is specific to one pet. A desktop companion, a sticker or a
status badge can all use it.

## What a pet learns

A pet never learns where any window is, how big it is, which one it is or
whose it is. It learns only this:

| Event | When | What it tells |
| --- | --- | --- |
| `placed(x, y)` | The user let it go free | Its own top left, on its own output |
| `held(hold)` | The user let it go on a window | Which kind of hold: an edge or a corner |
| `carried(vx, vy)` | While its window moves it on screen; from version 3, also while the user drags it | How fast, in logical px/s; zero when it stops |
| `released` | Its window closed, maximized or went fullscreen | That it is back at its anchors and margins |
| `pointer(x, y)` | While it watches the pointer (version 2): about once a second, when the direction changes by more than 2° | Which way the pointer is from its anchor, a unit vector; never how far |

- **Only the user gives a pet a window.** A pet is held only where the user
  drops it, after a drag the compositor runs from a fresh press on the pet
  (`move` with that press's serial). A pet cannot probe for windows.
- **A held pet cannot move itself.** Its layer surface's anchors and margins
  are ignored until it is released.
- **Velocity during the user's drag only from version 3.** It lets a pet
  sway as it is carried about. With it, the pet can work out roughly where
  it was dropped, and so roughly where its window is: the Doctor chose that
  over rounding it (2026-10-09). The compositor measures it from the pointer
  that moves the pet, at most every 16 ms, and sends zero 48 ms after the
  last move and before the pet is placed or held.
- **A direction, never a distance.** A pet that asks (`watch_pointer`)
  learns which way the pointer is, so its eyes can follow it, but not where
  it is. Nothing is sent while the user drags the pet. The compositor
  measures it, from the pointer and the pet's anchor as it places them.
- **No more reach than a top layer.** A held pet is stacked with its window,
  just above it or just below it, and its input is its own shape.

## Who decides what

| Part | Its job |
| --- | --- |
| The pet's client | Says which point holds on (`set_anchor`), what may hold it (`set_holds`) and how it stacks (`set_stacking`); starts drags from presses on itself |
| The compositor | Checks the press and runs the drag. Keeps the pet's protocol state. Checks every decision the shell makes. Tells the pet only what the table above allows. Releases pets whose window closes, maximizes or goes fullscreen |
| The shell | While the user drags a pet, decides which window would hold it, from what the user sees. Draws a held pet with its window. Reports how fast a held pet moves on screen |
| A pet plugin | Provides the shell's rule for holds, the `ShellPetHolds` contract, and what a held pet casts on its window, `ShellPetShadows`. The first-party `denial_pets` plugin snaps to edges and corners within 12 px and casts a contact shadow |

## Shell wire

The compositor publishes each pet layer in `Window` (`protocol/denial.fbs`):
- `pet`, `pet_holds`, `pet_anchor_x/y`, `pet_below` and `pet_dragged`;
- `held_by_window_id`, `held_hold` and `held_share` for the window holding
  it. While the pet is dragged, these name the hold it takes if let go now.

The shell answers with `PetRequest`:

- **`Hold`**, while the user drags a pet: the window's object id, one hold
  value and the share along an edge; or window id zero for none.
  - The compositor keeps it only if the pet is being dragged, accepts that
    hold, and the window may hold pets (it is not fullscreen or maximized).
  - It applies the latest one when the user lets go.
- **`Carried`**, while a held pet moves on screen: its velocity in logical
  px/s, every animation of its window included. The compositor forwards it
  to a held pet and ignores it for any other.

In the SDK, these are `DenialBridge.holdPet` and `DenialBridge.carryPet`. A
pet's state is `DenialWindow.pet` (`package:denial_flutter_sdk/pets.dart`).

## In the reference desktop

- **While the user drags a pet,** `DesktopPetHoldPublisher` asks the selected
  `ShellPetHolds` for a hold, passing what the user sees front to back:
  panels, windows with their popups and held pets, and the screens.
- **A held pet is drawn by its window's frame.** It sits inside the
  transforms that move the window: drags, settling, layout reflow, workspace
  slides, minimize, the overview and the switcher. It fades with the window
  when minimized, but not with the window's own translucency.
  - `above` pets are just over the window and under its popups.
  - `below` pets are just under the window.
  - What `above` pets cast, from the selected `ShellPetShadows`, is just
    under them all, clipped to the window's visible frame.
- **Its input** takes its window's z, in the same order.
- **`DesktopPetCarry`** reads the pet's hold point after each frame the shell
  draws anyway, and reports its velocity at most every 16 ms. It sends zero
  48 ms after the last move.
