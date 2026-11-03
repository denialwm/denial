import 'dart:ui' show Offset, Rect;

import 'package:flutter/physics.dart' show SpringDescription;
import 'package:motor/motor.dart' as motor;

import 'motion.dart' show Motion;

/// The shell's physical motion: springs that keep their velocity when a
/// gesture or a new target redirects them.
///
/// Spatial springs move geometry (position, size). Effects springs change
/// how something looks (opacity, colour); they are critically damped and
/// never overshoot. Durations are the spring's perceived duration, as in
/// SwiftUI: the time to travel most of the way, not to rest.
abstract final class ShellSprings {
  /// An app growing out of its icon. The little bounce carries the card
  /// past the screen's edges, where no one sees it, and lets it arrive
  /// sooner than a critically damped spring would.
  static const motor.Motion appOpen = motor.CupertinoMotion(
    duration: Duration(milliseconds: 400),
    bounce: 0.06,
  );

  /// An app returning into its icon: a little slower than opening, with a
  /// soft landing that the icon visibly absorbs.
  static const motor.Motion appClose = motor.CupertinoMotion(
    duration: Duration(milliseconds: 460),
    bounce: 0.12,
  );

  /// Recents settling open around a released card, or closing back into
  /// the app. The finger's speed carries over; both reach their end exactly,
  /// so recents unmounts when closed.
  static const motor.Motion recentsOpen = motor.SpringMotion(
    Motion.gentle,
    snapToEnd: true,
  );
  static const motor.Motion recentsClose = motor.SpringMotion(
    Motion.snappy,
    snapToEnd: true,
  );

  /// The row of apps moving sideways: a switch between apps, recents
  /// bringing an app to the centre, and the row closing over a dismissed
  /// card. The finger's speed carries over, and it lands exactly, so a
  /// switch ends on the app it heads for.
  static const motor.Motion appStrip = motor.SpringMotion(
    Motion.snappy,
    snapToEnd: true,
  );

  /// Recents flung past its first or last card: the row runs on past it
  /// with the fling's speed and bounces back.
  static const motor.Motion recentsEdge = motor.SpringMotion(
    SpringDescription(mass: 1.0, stiffness: 300.0, damping: 24.0),
    snapToEnd: true,
  );

  /// A recents card let go before it was dismissed springs back into its
  /// slot with a little bounce; a dismissed one leaves at the finger's speed.
  static const motor.Motion cardReturn = motor.SpringMotion(Motion.bouncy);
  static const motor.Motion cardDismiss = motor.SpringMotion(Motion.snappy);

  /// Content changing in place, such as a placeholder giving way to the
  /// app's first frame.
  static const motor.Motion contentFade = motor.CupertinoMotion(
    duration: Duration(milliseconds: 180),
  );
}

/// Animates a [Rect] as its centre and size rather than its four edges.
///
/// Edge springs would let opposite sides settle at different moments and
/// skew the shape; centre and size keep a card's proportions coherent, and
/// carry a finger's velocity as one centre velocity.
class RectCenterSizeConverter extends motor.MotionConverter<Rect> {
  const RectCenterSizeConverter();

  @override
  List<double> normalize(Rect value) => [
    value.center.dx,
    value.center.dy,
    value.width,
    value.height,
  ];

  @override
  Rect denormalize(List<double> values) => Rect.fromCenter(
    center: Offset(values[0], values[1]),
    width: values[2] < 0 ? 0 : values[2],
    height: values[3] < 0 ? 0 : values[3],
  );
}
