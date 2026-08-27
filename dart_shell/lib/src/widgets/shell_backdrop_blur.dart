import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';

/// A tightly clipped, layout-aware blur for translucent compositor surfaces.
///
/// Every instance owns its backdrop unless [grouped] is true. Windows must
/// never be grouped because they can overlap; non-overlapping siblings such as
/// system-bar pills can opt into one shared engine blur through [BackdropGroup].
class ShellBackdropBlur extends StatelessWidget {
  const ShellBackdropBlur({
    required this.child,
    this.blur = true,
    this.grouped = false,
    this.useWindowAlphaThreshold = false,
    this.singleWindowSurface = false,
    this.strength = 1,
    this.borderRadius,
    this.blendMode = ui.BlendMode.src,
    super.key,
  }) : assert(strength >= 0 && strength <= 1);

  final Widget child;
  final bool blur;
  final bool grouped;
  final bool useWindowAlphaThreshold;
  final bool singleWindowSurface;
  final double strength;
  final BorderRadiusGeometry? borderRadius;
  final ui.BlendMode blendMode;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final resolvedStrength = strength.clamp(0.0, 1.0).toDouble();
    final available =
        blur &&
        theme.backdropBlurEnabled &&
        theme.backdropBlurSigma > 0 &&
        (!useWindowAlphaThreshold || theme.backdropBlurOpacityThreshold < 1.0);
    final enabled = available && resolvedStrength > 0;
    final Widget filtered;
    if (available) {
      final filterConfig = useWindowAlphaThreshold
          ? singleWindowSurface
                ? theme.singleSurfaceWindowBackdropBlurFilterConfig
                : theme.windowBackdropBlurFilterConfig
          : theme.backdropBlurFilterConfigAt(resolvedStrength);
      filtered = grouped
          ? BackdropFilter.grouped(
              filterConfig: filterConfig,
              blendMode: blendMode,
              enabled: enabled,
              child: child,
            )
          : BackdropFilter(
              filterConfig: filterConfig,
              blendMode: blendMode,
              enabled: enabled,
              child: child,
            );
    } else {
      filtered = child;
    }

    final radius = borderRadius;
    if (radius == null) {
      return available
          ? ClipRect(clipBehavior: Clip.hardEdge, child: filtered)
          : filtered;
    }
    if (radius == BorderRadius.zero) {
      return ClipRect(clipBehavior: Clip.hardEdge, child: filtered);
    }
    return ClipRRect(
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: filtered,
    );
  }
}
