import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart';

// The reference device renders its 1220 px-wide panel at Android's configured
// 480 dpi density, which is exactly 406 2/3 dp.
const double colorOsReferenceShortSide = 1220 / 3;

@visibleForTesting
double colorOsShadeScaleForViewport(Size size) {
  final shortSide = size.shortestSide;
  if (!shortSide.isFinite || shortSide <= 0) return 1;
  return shortSide / colorOsReferenceShortSide;
}

/// Separates ColorOS layout geometry from Denial's native text and glyph size.
///
/// Tile frames and spacing use [scale]. Text and icons use [inverseScale] so
/// the enclosing geometry transform does not enlarge their painted content.
class ShadeReferenceGeometry extends InheritedWidget {
  const ShadeReferenceGeometry({
    super.key,
    required this.scale,
    required super.child,
  });

  final double scale;

  static double scaleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShadeReferenceGeometry>()
          ?.scale ??
      1;

  static double inverseScaleOf(BuildContext context) => 1 / scaleOf(context);

  @override
  bool updateShouldNotify(ShadeReferenceGeometry oldWidget) =>
      scale != oldWidget.scale;
}
