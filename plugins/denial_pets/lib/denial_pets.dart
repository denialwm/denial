@Plugin()
library;

import 'package:denial_flutter_sdk/pets.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/contact.dart';
import 'src/contact_shadow.dart';
import 'src/perch.dart';

/// Pets perch on the window edges and corners the user sees: a dragged pet
/// takes the first hold it accepts within [perchReach] of its anchor, of the
/// frontmost window that has one, if nothing covers that point and it shows
/// on a screen.
@Provides(ShellPetHolds)
final class PerchHolds implements ShellPetHolds {
  const PerchHolds();

  @override
  DenialPetHold? holdFor(PetDrag drag) {
    final found = perch(
      anchor: (x: drag.anchor.dx, y: drag.anchor.dy),
      holds: drag.pet.pet?.holds ?? 0,
      targets: [
        for (final target in drag.targets)
          (
            rect: _box(target.rect),
            window: target.window,
            frame: switch (target.frame) {
              final frame? => _box(frame),
              null => null,
            },
          ),
      ],
      screens: [for (final screen in drag.screens) _box(screen)],
    );
    if (found == null) return null;
    final hold = DenialWindowHold.fromValue(found.hold);
    return hold == null
        ? null
        : DenialPetHold(windowId: found.window, hold: hold, share: found.share);
  }

  static PerchBox _box(Rect rect) =>
      (left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom);
}

/// A held pet casts a little contact shadow on its window: its own shape,
/// dark and soft, where it touches the edge or corner it holds on by.
@Provides(ShellPetShadows)
final class ContactShadows implements ShellPetShadows {
  const ContactShadows();

  @override
  Widget? shadowFor(PetShadow shadow) {
    final height = shadow.size.height;
    final fade = contactFade(
      hold: shadow.hold.value,
      anchor: (x: shadow.anchor.dx, y: shadow.anchor.dy),
      reach: contactReach * height,
    );
    return fade == null
        ? null
        : ContactShadow(
            shadow: shadow,
            fade: fade,
            drop: contactDrop * height,
            softness: contactSoftness * height,
          );
  }
}
