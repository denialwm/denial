import 'package:flutter/widgets.dart';

// The reference device renders its 1220 px-wide panel at Android's configured
// 480 dpi density, which is exactly 406 2/3 dp.
const double colorOsReferenceShortSide = 1220 / 3;

/// Maps a viewport to the shared shade reference geometry.
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

/// The status-bar clock grows into the open shade's header and carries the
/// date beneath it. Sizes are logical pixels; both shade pages reserve the
/// same block below the status row.
abstract final class ShadeHeaderClock {
  /// The status-bar clock's font size; its line height is the font size.
  static const double fontSize = 18.15;

  /// The clock's font size in the open shade's header.
  static const double expandedFontSize = 66;
  static const double expandedScale = expandedFontSize / fontSize;
  static const double dateGap = 12;
  static const double dateFontSize = 26;
  static const double blockHeight = expandedFontSize + dateGap + dateFontSize;

  /// Start edge of the expanded block, in reference units, so the clock
  /// lines up with the quick-settings tiles.
  static const double inset = 28;

  /// Reference-unit gap between the status row and the header block.
  static const double statusGap = 12;
}
