import 'package:flutter/widgets.dart';

/// Where a window holds a desktop pet (denial-pet-v1): an edge or a corner
/// of the window's visible frame. [value] is the protocol's hold value.
enum DenialWindowHold {
  top(1),
  bottom(2),
  left(4),
  right(8),
  topLeft(16),
  topRight(32),
  bottomLeft(64),
  bottomRight(128);

  const DenialWindowHold(this.value);

  final int value;

  /// Whether this is a corner, which holds a pet on its point.
  bool get isCorner => value >= topLeft.value;

  /// The hold with the protocol value [value], or null for any other value.
  static DenialWindowHold? fromValue(int value) {
    for (final hold in values) {
      if (hold.value == value) return hold;
    }
    return null;
  }

  /// The holds or-ed into [mask], corners first.
  static List<DenialWindowHold> fromMask(int mask) => [
    for (final hold in const [
      topLeft,
      topRight,
      bottomLeft,
      bottomRight,
      top,
      bottom,
      left,
      right,
    ])
      if (mask & hold.value != 0) hold,
  ];

  /// The point of [frame] this hold holds by, [share] along an edge from its
  /// left or top end.
  Offset pointOn(Rect frame, double share) => switch (this) {
    top => Offset(frame.left + share * frame.width, frame.top),
    bottom => Offset(frame.left + share * frame.width, frame.bottom),
    left => Offset(frame.left, frame.top + share * frame.height),
    right => Offset(frame.right, frame.top + share * frame.height),
    topLeft => frame.topLeft,
    topRight => frame.topRight,
    bottomLeft => frame.bottomLeft,
    bottomRight => frame.bottomRight,
  };
}

/// A window holding a desktop pet: the window's object id, which edge or
/// corner, and where along an edge, from its left or top end, as a share of
/// it. Unused for a corner.
@immutable
class DenialPetHold {
  const DenialPetHold({
    required this.windowId,
    required this.hold,
    this.share = 0.0,
  });

  final int windowId;
  final DenialWindowHold hold;
  final double share;

  @override
  bool operator ==(Object other) =>
      other is DenialPetHold &&
      other.windowId == windowId &&
      other.hold == hold &&
      other.share == share;

  @override
  int get hashCode => Object.hash(windowId, hold, share);

  @override
  String toString() => 'DenialPetHold($windowId, ${hold.name}, $share)';
}

/// What the shell knows of a desktop pet: a layer surface the user may drop
/// on a window's edge or corner (denial-pet-v1). The pet's client knows none
/// of this beyond the kind of hold it is let go on.
@immutable
class DenialPet {
  const DenialPet({
    this.holds = 0,
    this.anchor = Offset.zero,
    this.below = false,
    this.dragged = false,
    this.held,
  });

  /// The holds it accepts: protocol hold values, or-ed. See [accepts].
  final int holds;

  /// The point it holds on by, in its own logical coordinates.
  final Offset anchor;

  /// Whether it stacks just below its window while held, instead of just
  /// above it.
  final bool below;

  /// Whether the user is dragging it. Its layer's geometry then follows the
  /// pointer.
  final bool dragged;

  /// The window holding it. While [dragged], the hold it takes if let go now.
  final DenialPetHold? held;

  /// Whether it accepts [hold].
  bool accepts(DenialWindowHold hold) => holds & hold.value != 0;

  @override
  bool operator ==(Object other) =>
      other is DenialPet &&
      other.holds == holds &&
      other.anchor == anchor &&
      other.below == below &&
      other.dragged == dragged &&
      other.held == held;

  @override
  int get hashCode => Object.hash(holds, anchor, below, dragged, held);
}
