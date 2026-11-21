import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/display_layout.dart';

/// How much larger than its screen's scale the desktop shell draws itself on
/// one screen.
///
/// The shell is laid out in its own units and drawn this many screen units
/// per shell unit. Windows and apps keep the screen's scale, and everything
/// the shell tells the compositor stays in the screen's own units.
abstract final class ShellScale {
  static const double minimum = 0.75;
  static const double maximum = 3.0;

  /// The shell's scale on a built-in panel the handheld density rule scaled:
  /// the desktop shell is drawn at desktop sizes, which come out small on
  /// such a panel.
  static const double handheldPanel = 1.25;

  /// The scale a screen takes when none is stored for it.
  static double automatic(DisplayOutput output) =>
      output.name.startsWith('DSI-') && output.scale > 1.0
      ? handheldPanel
      : 1.0;

  /// The scale of [output]: the stored value, else [automatic].
  static double of(DisplayOutput output, Map<String, double> stored) {
    final value = stored[output.name];
    if (value != null &&
        value.isFinite &&
        value >= minimum &&
        value <= maximum) {
      return value;
    }
    return automatic(output);
  }

  /// The desktop shell's scale on [output]. With [desktopPanels] false the
  /// mobile shell has the built-in panels and the desktop shell's scale
  /// there is 1.
  static double forDesktop(
    DisplayOutput output,
    Map<String, double> stored, {
    required bool desktopPanels,
  }) {
    if (!desktopPanels && _builtInPanel(output.name)) {
      return 1.0;
    }
    return of(output, stored);
  }

  static bool _builtInPanel(String name) =>
      name.startsWith('DSI-') ||
      name.startsWith('eDP-') ||
      name.startsWith('LVDS-');

  /// [length] shell units as screen units on a screen of [screenScale]: a
  /// whole number of screen units that is also a whole number of device
  /// pixels, as near to [length] × [shellScale] as that allows. A length that
  /// is not zero stays at least one such step. At a shell scale of 1 the
  /// length is returned as it is.
  static double length(double length, double shellScale, double screenScale) {
    if (shellScale == 1.0 || !length.isFinite || length <= 0.0) {
      return length;
    }
    final step = wholePixelStep(screenScale);
    final steps = (length * shellScale / step).round();
    return math.max(1, steps) * step;
  }

  /// The smallest whole number of screen units that is a whole number of
  /// device pixels at [screenScale], or 1 when none up to 8 is.
  static double wholePixelStep(double screenScale) {
    if (!screenScale.isFinite || screenScale <= 0.0) {
      return 1.0;
    }
    for (var units = 1; units <= 8; units += 1) {
      final pixels = units * screenScale;
      if ((pixels - pixels.roundToDouble()).abs() < 1e-6) {
        return units.toDouble();
      }
    }
    return 1.0;
  }

  /// [rect], in screen units, in the shell's units on an output whose
  /// top-left corner is [origin]: the origin stays, everything else is
  /// [shellScale] times smaller.
  static Rect toShell(Rect rect, Offset origin, double shellScale) {
    if (shellScale == 1.0) return rect;
    return Rect.fromLTWH(
      origin.dx + (rect.left - origin.dx) / shellScale,
      origin.dy + (rect.top - origin.dy) / shellScale,
      rect.width / shellScale,
      rect.height / shellScale,
    );
  }

  /// [rect], in the shell's units on an output whose top-left corner is
  /// [origin], in screen units.
  static Rect toScreen(Rect rect, Offset origin, double shellScale) {
    if (shellScale == 1.0) return rect;
    return Rect.fromLTWH(
      origin.dx + (rect.left - origin.dx) * shellScale,
      origin.dy + (rect.top - origin.dy) * shellScale,
      rect.width * shellScale,
      rect.height * shellScale,
    );
  }

  /// [insets] scaled side by side with [length].
  static EdgeInsets insets(
    EdgeInsets insets,
    double shellScale,
    double screenScale,
  ) {
    if (shellScale == 1.0) {
      return insets;
    }
    return EdgeInsets.fromLTRB(
      length(insets.left, shellScale, screenScale),
      length(insets.top, shellScale, screenScale),
      length(insets.right, shellScale, screenScale),
      length(insets.bottom, shellScale, screenScale),
    );
  }
}
