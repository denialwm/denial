# Desktop Pets

Lets windows hold desktop pets: layer surfaces that use Denial's
`denial-pet-v1` protocol, such as a desktop companion. When the user drags a
pet near the edge or corner of a window, the pet perches there, and the
window carries it from then on.

This plugin provides `ShellPetHolds` from `package:denial_flutter_sdk/pets.dart`:

- A dragged pet takes the first hold it accepts within 12 logical pixels of
  its anchor: corners before edges, on the frontmost window that has one.
- The hold must show: on a screen, and not under anything in front of the
  window, panels and other pets included.
- An edge holds the pet anywhere along it. A corner holds it on its point.

The perching rule is plain Dart in `lib/src/perch.dart`, tested with
`dart test`.

It also provides `ShellPetShadows`: a held pet casts a contact shadow on its
window. The shadow is the pet's own shape, 90% black, blurred and a little
lower. It fades out within a tenth of the pet's height of the edge or corner
it holds on by, so only what touches the window casts, such as a sitting
pet's skirt and thighs. Its sizes follow the pet's drawn height. Where it shows is plain Dart in `lib/src/contact.dart`, and
`lib/src/contact_shadow.dart` draws it.

## Writing another pet plugin

Provide your own `ShellPetHolds`. While the user drags a pet, the desktop
calls `holdFor` with a `PetDrag`:

- the pet, with the holds it accepts;
- where the pointer puts its anchor;
- what the user sees, front to back;
- the screens.

Return a `DenialPetHold` naming a window, an edge or corner and a share along
the edge, or null to leave the pet free. Denial applies the last hold when
the user lets go. It refuses holds the pet does not accept, and windows that
are fullscreen or maximized.

The pet's own client only ever learns the kind of hold, never where anything
is. A plugin may therefore use everything the user sees.

Only one `ShellPetHolds` and one `ShellPetShadows` can be selected at a
time. Deselect this plugin to select another provider of either.
