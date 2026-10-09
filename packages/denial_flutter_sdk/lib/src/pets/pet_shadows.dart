import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import '../models/denial_pet.dart';
import '../models/denial_window.dart';

/// Draws what a held desktop pet casts on the window holding it, such as a
/// contact shadow (denial-pet-v1). Selected when the shell is compiled;
/// without one, held pets cast nothing.
///
/// The host draws the returned widget over the pet's rectangle, just under
/// every pet the window holds and clipped to the window's visible frame,
/// inside the transforms that move the window, so it moves, fades and
/// minimizes with it. Only pets stacked above their window cast. Nothing of
/// it reaches the pet's client.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrOne)
abstract interface class ShellPetShadows {
  /// What [shadow]'s pet casts on its window, or null for nothing.
  Widget? shadowFor(PetShadow shadow);
}

/// A held desktop pet about to be drawn on its window. Sizes and points are
/// in the pet's drawn rectangle, logical pixels.
@immutable
class PetShadow {
  const PetShadow({
    required this.pet,
    required this.hold,
    required this.size,
    required this.anchor,
    required this.surface,
  });

  /// The pet's layer surface.
  final DenialWindow pet;

  /// The edge or corner of its window that holds it.
  final DenialWindowHold hold;

  /// The pet's drawn rectangle: what the returned widget covers.
  final Size size;

  /// The point it holds on by, which lies on [hold]'s edge or corner.
  final Offset anchor;

  /// The pet's surface as drawn, to shape what it casts from its pixels.
  final Widget surface;
}
