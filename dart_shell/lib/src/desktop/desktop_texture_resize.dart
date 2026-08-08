import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Whether a live client texture is being mapped into a differently sized
/// desktop frame. Native keeps the last complete buffer alive during this
/// interval; high-quality sampling keeps that deliberate stretch clean.
bool desktopTextureNeedsResizeSmoothing({
  required Size targetSize,
  required Size sourceSize,
}) {
  if (targetSize.isEmpty || sourceSize.isEmpty) {
    return false;
  }

  bool differs(double target, double source) {
    final tolerance = math.max(
      1.0,
      math.max(target.abs(), source.abs()) * 0.001,
    );
    return (target - source).abs() > tolerance;
  }

  return differs(targetSize.width, sourceSize.width) ||
      differs(targetSize.height, sourceSize.height);
}
