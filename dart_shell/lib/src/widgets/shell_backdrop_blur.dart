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
    this.borderRadius,
    this.blendMode = ui.BlendMode.src,
    super.key,
  });

  final Widget child;
  final bool blur;
  final bool grouped;
  final BorderRadiusGeometry? borderRadius;
  final ui.BlendMode blendMode;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final enabled =
        blur && theme.backdropBlurEnabled && theme.backdropBlurSigma > 0;
    final Widget filtered;
    if (enabled) {
      final filterConfig = ImageFilterConfig.blur(
        sigmaX: theme.backdropBlurSigma,
        sigmaY: theme.backdropBlurSigma,
        tileMode: ui.TileMode.clamp,
      );
      filtered = grouped
          ? BackdropFilter.grouped(
              filterConfig: filterConfig,
              blendMode: blendMode,
              child: child,
            )
          : BackdropFilter(
              filterConfig: filterConfig,
              blendMode: blendMode,
              child: child,
            );
    } else {
      filtered = child;
    }

    final radius = borderRadius;
    if (radius == null) {
      return enabled
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
