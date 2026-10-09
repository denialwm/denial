/// Where a desktop pet perches: the window edge or corner nearest its anchor,
/// as the user sees the windows. Plain Dart, so it is tested without an
/// engine; `denial_pets.dart` adapts it to the SDK.
library;

import 'dart:math' as math;

/// How near a hold the pet's anchor must come to take it, in logical pixels.
const perchReach = 12.0;

/// Every protocol hold value, corners first: a corner within reach wins over
/// its edges.
const perchHolds = <int>[
  _topLeft,
  _topRight,
  _bottomLeft,
  _bottomRight,
  _top,
  _bottom,
  _left,
  _right,
];

const _top = 1;
const _bottom = 2;
const _left = 4;
const _right = 8;
const _topLeft = 16;
const _topRight = 32;
const _bottomLeft = 64;
const _bottomRight = 128;

typedef PerchPoint = ({double x, double y});
typedef PerchBox = ({double left, double top, double right, double bottom});

/// Something the user sees, front to back: what it covers and, for a window
/// that may hold pets, its id and visible frame.
typedef PerchTarget = ({PerchBox rect, int? window, PerchBox? frame});

/// A window's hold on a pet: the window, the protocol hold value and the
/// share along an edge.
typedef Perch = ({int window, int hold, double share});

/// The point of [frame] that [hold] holds by, [share] along an edge.
PerchPoint perchPoint(PerchBox frame, int hold, double share) {
  final across = frame.left + share * (frame.right - frame.left);
  final down = frame.top + share * (frame.bottom - frame.top);
  return switch (hold) {
    _top => (x: across, y: frame.top),
    _bottom => (x: across, y: frame.bottom),
    _left => (x: frame.left, y: down),
    _right => (x: frame.right, y: down),
    _topLeft => (x: frame.left, y: frame.top),
    _topRight => (x: frame.right, y: frame.top),
    _bottomLeft => (x: frame.left, y: frame.bottom),
    _ => (x: frame.right, y: frame.bottom),
  };
}

/// How far [anchor] is from [hold] of [frame], and its share along the edge;
/// null when it is beside an edge's ends.
({double distance, double share})? _reach(
  PerchBox frame,
  int hold,
  PerchPoint anchor,
) {
  final across = anchor.x >= frame.left && anchor.x <= frame.right;
  final down = anchor.y >= frame.top && anchor.y <= frame.bottom;
  final shareAcross = (anchor.x - frame.left) / (frame.right - frame.left);
  final shareDown = (anchor.y - frame.top) / (frame.bottom - frame.top);
  switch (hold) {
    case _top when across:
      return (distance: (anchor.y - frame.top).abs(), share: shareAcross);
    case _bottom when across:
      return (distance: (anchor.y - frame.bottom).abs(), share: shareAcross);
    case _left when down:
      return (distance: (anchor.x - frame.left).abs(), share: shareDown);
    case _right when down:
      return (distance: (anchor.x - frame.right).abs(), share: shareDown);
    case _topLeft || _topRight || _bottomLeft || _bottomRight:
      final point = perchPoint(frame, hold, 0.0);
      final dx = anchor.x - point.x;
      final dy = anchor.y - point.y;
      return (distance: math.sqrt(dx * dx + dy * dy), share: 0.0);
    default:
      return null;
  }
}

/// Whether [point] is inside [box], its far edges excluded.
bool _covers(PerchBox box, PerchPoint point) =>
    point.x >= box.left &&
    point.y >= box.top &&
    point.x < box.right &&
    point.y < box.bottom;

/// The hold that takes a pet whose anchor is at [anchor] and which accepts
/// [holds] (protocol hold values, or-ed): of the frontmost window with an
/// accepted hold within [reach], the first such hold, corners before edges,
/// if its point is on one of [screens] and nothing in front of the window
/// covers it.
Perch? perch({
  required PerchPoint anchor,
  required int holds,
  required List<PerchTarget> targets,
  required List<PerchBox> screens,
  double reach = perchReach,
}) {
  for (var index = 0; index < targets.length; index += 1) {
    final target = targets[index];
    final window = target.window;
    final frame = target.frame;
    if (window == null ||
        frame == null ||
        frame.right <= frame.left ||
        frame.bottom <= frame.top) {
      continue;
    }
    for (final hold in perchHolds) {
      if (holds & hold == 0) continue;
      final found = _reach(frame, hold, anchor);
      if (found == null || found.distance > reach) continue;
      final share = found.share.clamp(0.0, 1.0);
      final point = perchPoint(frame, hold, share);
      final covered = targets
          .take(index)
          .any((front) => _covers(front.rect, point));
      final shown = screens.any((screen) => _covers(screen, point));
      if (!covered && shown) {
        return (window: window, hold: hold, share: share);
      }
      // What holds it first is hidden: a window further back may show.
      break;
    }
  }
  return null;
}
