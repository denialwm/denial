import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';
import '../theme/glass_configuration.dart';

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
    this.separateChild = false,
    this.strength = 1,
    this.borderRadius,
    this.blendMode = ui.BlendMode.src,
    super.key,
  }) : assert(strength >= 0 && strength <= 1),
       assert(!separateChild || !useWindowAlphaThreshold),
       assert(!separateChild || blendMode == ui.BlendMode.src);

  final Widget child;
  final bool blur;
  final bool grouped;
  final bool useWindowAlphaThreshold;
  final bool singleWindowSurface;

  /// Paint foreground controls after the backdrop assignment. This keeps
  /// their geometry out of the filter's intermediate color layer. Window
  /// alpha-threshold materials need the foreground inside that layer instead.
  final bool separateChild;
  final double strength;
  final BorderRadiusGeometry? borderRadius;
  final ui.BlendMode blendMode;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final resolvedStrength = strength.clamp(0.0, 1.0).toDouble();
    final radius = borderRadius?.resolve(Directionality.of(context));
    final available =
        blur &&
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0) &&
        (!useWindowAlphaThreshold || theme.backdropBlurOpacityThreshold < 1.0);
    final enabled = available && resolvedStrength > 0;
    final Widget filtered;
    if (available) {
      final filterConfig = theme.backdropFilterConfigAt(
        resolvedStrength,
        borderRadius: radius ?? BorderRadius.zero,
        useWindowAlphaThreshold: useWindowAlphaThreshold,
        singleWindowSurface: singleWindowSurface,
      );
      final filterChild = separateChild ? const SizedBox.expand() : child;
      final backdrop = grouped
          ? BackdropFilter.grouped(
              filterConfig: filterConfig,
              blendMode: blendMode,
              enabled: enabled,
              child: filterChild,
            )
          : BackdropFilter(
              filterConfig: filterConfig,
              blendMode: blendMode,
              enabled: enabled,
              child: filterChild,
            );
      filtered = separateChild
          ? Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(child: backdrop),
                child,
              ],
            )
          : backdrop;
    } else {
      filtered = child;
    }

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
