import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import '../models/denial_pet.dart';
import '../models/denial_window.dart';

/// Decides which window holds a desktop pet the user drags (denial-pet-v1).
/// Selected when the shell is compiled; without one, pets are only ever let
/// go free.
///
/// While the user drags a pet, the host asks again whenever the pet or the
/// scene changes, and passes the answer to the compositor. The compositor
/// keeps it only if the pet accepts that hold and the window may hold pets
/// (it is not fullscreen or maximized), and applies the latest one when the
/// user lets go. The host then draws the pet with that window.
///
/// The pet's own client learns only the kind of hold it is let go on, never
/// where anything is, so a provider may use everything the user sees.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrOne)
abstract interface class ShellPetHolds {
  /// The hold [drag]'s pet takes if let go now, or null to leave it free.
  DenialPetHold? holdFor(PetDrag drag);
}

/// A desktop pet the user drags, and what the user sees around it. All
/// rectangles and points are in desktop scene coordinates, logical pixels.
@immutable
class PetDrag {
  const PetDrag({
    required this.pet,
    required this.anchor,
    required this.targets,
    required this.screens,
  });

  /// The pet's layer surface. Its [DenialWindow.pet] has the holds it
  /// accepts and the hold it was last given in this drag.
  final DenialWindow pet;

  /// Where the pointer puts the point the pet holds on by.
  final Offset anchor;

  /// What the user sees, front to back: the windows, and anything drawn over
  /// them, such as panels and other pets. The dragged pet is left out.
  final List<PetHoldTarget> targets;

  /// The screens.
  final List<Rect> screens;

  /// Whether [point] shows on a screen.
  bool onScreen(Offset point) =>
      screens.any((screen) => _covers(screen, point));

  /// Whether anything in [targets] before [index] covers [point].
  bool coveredBefore(int index, Offset point) =>
      targets.take(index).any((front) => _covers(front.rect, point));

  /// Whether [point] is inside [rect], its far edges excluded.
  static bool _covers(Rect rect, Offset point) =>
      point.dx >= rect.left &&
      point.dy >= rect.top &&
      point.dx < rect.right &&
      point.dy < rect.bottom;
}

/// Something the user sees while dragging a pet.
@immutable
class PetHoldTarget {
  const PetHoldTarget({required this.rect, this.window, this.frame});

  /// What it covers.
  final Rect rect;

  /// For a window that may hold pets, its object id; null for anything else,
  /// including windows that let pets go, such as fullscreen ones.
  final int? window;

  /// For a window that may hold pets, its visible frame: its content with
  /// the frame the shell draws around it. Holds lie on its edges and corners.
  final Rect? frame;

  /// Whether this is a window that may hold pets.
  bool get holdsPets => window != null && frame != null;
}
