import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';
import 'desktop_window_render_telemetry.dart';
import 'desktop_workspace.dart';

Color desktopWindowBorderColor({
  required bool pinned,
  required bool active,
  required ShellThemeData theme,
  required Color inactiveColor,
}) {
  if (pinned) {
    return theme.accentPalette.container;
  }
  if (active && theme.focusedWindowBorderEnabled) {
    return theme.accent;
  }
  return inactiveColor;
}

/// Keeps the static server-side decoration isolated from the live client
/// texture and from the stateful focus border.
///
/// Only the shadow picture is marked complex. Applying the hint to a single
/// [CustomPaint] with both a background and foreground painter would also
/// force a full-window cache for the inexpensive frame and focus border.
class DesktopWindowFrameLayers extends StatelessWidget {
  const DesktopWindowFrameLayers({
    required this.windowId,
    required this.devicePixelRatio,
    required this.radius,
    required this.frameColor,
    required this.borderColor,
    required this.child,
    super.key,
  });

  final int windowId;
  final double devicePixelRatio;
  final double radius;
  final Color frameColor;
  final Color borderColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        DesktopWindowRepaintBoundary(
          outset: DesktopWindowShadowPainter.shadowOutset,
          child: IgnorePointer(
            child: CustomPaint(
              painter: DesktopWindowShadowPainter(
                windowId: windowId,
                radius: radius,
                shadowColor: context.shellColors.shadow,
              ),
              isComplex: true,
              willChange: false,
            ),
          ),
        ),
        child,
        IgnorePointer(
          child: CustomPaint(
            painter: DesktopWindowFramePainter(
              windowId: windowId,
              devicePixelRatio: devicePixelRatio,
              radius: radius,
              frameColor: frameColor,
              borderColor: borderColor,
            ),
          ),
        ),
      ],
    );
  }
}

/// A retained layer whose damage bounds include deliberate child overdraw.
///
/// [DesktopWindowShadowPainter] paints its shadow outside the window's layout
/// rectangle. A normal [RepaintBoundary] would advertise only that rectangle,
/// leaving the outsetting shadow outside partial-repaint damage.
class DesktopWindowRepaintBoundary extends RepaintBoundary {
  const DesktopWindowRepaintBoundary({
    required this.outset,
    super.child,
    super.key,
  });

  final double outset;

  @override
  RenderDesktopWindowRepaintBoundary createRenderObject(BuildContext context) {
    return RenderDesktopWindowRepaintBoundary(outset);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDesktopWindowRepaintBoundary renderObject,
  ) {
    renderObject.outset = outset;
  }
}

class RenderDesktopWindowRepaintBoundary extends RenderRepaintBoundary {
  RenderDesktopWindowRepaintBoundary(this._outset) : assert(_outset >= 0);

  double _outset;

  set outset(double value) {
    assert(value >= 0);
    if (_outset == value) {
      return;
    }
    _outset = value;
    markNeedsPaint();
  }

  @override
  Rect get paintBounds => super.paintBounds.inflate(_outset);
}

/// Paints the cached shadow behind a decorated client surface.
class DesktopWindowShadowPainter extends CustomPainter {
  const DesktopWindowShadowPainter({
    this.windowId = 0,
    required this.radius,
    required this.shadowColor,
  });

  final int windowId;
  final double radius;
  final Color shadowColor;

  static const double shadowOutset = 64;

  @override
  void paint(Canvas canvas, Size size) {
    DesktopWindowRenderTelemetry.recordShadowPaint(windowId, size);
    if (size.isEmpty) {
      return;
    }

    final frame = Offset.zero & size;
    final frameShape = RRect.fromRectAndRadius(frame, Radius.circular(radius));
    final outsideFrame = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(frame.inflate(shadowOutset))
      ..addRRect(frameShape);
    final shadowRect = frame.shift(const Offset(0, 12)).inflate(2);
    final shadowPaint = Paint()
      ..color = shadowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16.5);

    canvas
      ..save()
      ..clipPath(outsideFrame)
      ..drawRRect(
        RRect.fromRectAndRadius(shadowRect, Radius.circular(radius * 1.25)),
        shadowPaint,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(covariant DesktopWindowShadowPainter oldDelegate) {
    return windowId != oldDelegate.windowId ||
        radius != oldDelegate.radius ||
        shadowColor != oldDelegate.shadowColor;
  }
}

typedef DesktopRoundedFrameGeometry = ({
  double borderThickness,
  double edgeHalfWidth,
  double frameThickness,
  double innerRadius,
  double outerRadius,
  double shaderRadius,
});

/// Resolves the coverage geometry used by the window frame.
///
/// The frame and its border stay in logical pixels so they retain the same
/// visual weight on every output. Only the antialiasing fringe is expressed in
/// physical pixels. Capping each half at half the frame thickness keeps the
/// inner and outer transitions from crossing when an unusually small frame is
/// requested.
DesktopRoundedFrameGeometry desktopRoundedFrameGeometry({
  required Size size,
  required double radius,
  required double frameThickness,
  required double borderThickness,
  required double devicePixelRatio,
}) {
  final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0.0
      ? devicePixelRatio
      : 1.0;
  final shortestSide = math.max(0.0, math.min(size.width, size.height));
  final resolvedRadius = math.min(math.max(0.0, radius), shortestSide / 2.0);
  final resolvedFrameThickness = math.min(
    math.max(0.0, frameThickness),
    shortestSide / 2.0,
  );
  final resolvedBorderThickness = math.min(
    math.max(0.0, borderThickness),
    resolvedFrameThickness,
  );
  final edgeHalfWidth = math.min(
    resolvedRadius,
    math.min(0.5 / ratio, resolvedFrameThickness / 2.0),
  );
  return (
    borderThickness: resolvedBorderThickness,
    edgeHalfWidth: edgeHalfWidth,
    frameThickness: resolvedFrameThickness,
    innerRadius: math.max(0.0, resolvedRadius - resolvedFrameThickness),
    outerRadius: resolvedRadius,
    shaderRadius: resolvedRadius + edgeHalfWidth,
  );
}

/// Paints the opaque frame and its stateful border with an analytic one-
/// physical-pixel coverage fringe.
///
/// Impeller can therefore render the rounded silhouette smoothly even when
/// the external GLES framebuffer is single-sampled. Four narrow edge strips
/// and four radius-sized corner patches are shaded; no save-layer or output-
/// sized attachment is allocated. The fringe extends half a physical pixel
/// beyond both boundaries so fractional-scale pixels are not dropped before
/// the shader can assign their coverage. The center stays clear so client-
/// provided per-pixel alpha keeps its existing compositing semantics.
class DesktopWindowFramePainter extends CustomPainter {
  const DesktopWindowFramePainter({
    this.windowId = 0,
    required this.devicePixelRatio,
    required this.radius,
    required this.frameColor,
    this.borderColor,
  });

  final int windowId;
  final double devicePixelRatio;
  final double radius;
  final Color frameColor;
  final Color? borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    DesktopWindowRenderTelemetry.recordBorderPaint(windowId, size);
    if (size.isEmpty) {
      return;
    }

    _paintRoundedFrame(
      canvas,
      Offset.zero & size,
      radius: radius,
      frameThickness: DesktopMetrics.frameBorder,
      borderThickness: DesktopMetrics.frameBorder,
      devicePixelRatio: _resolvedDevicePixelRatio,
      frameColor: frameColor,
      borderColor: borderColor,
    );
  }

  double get _resolvedDevicePixelRatio =>
      devicePixelRatio.isFinite && devicePixelRatio > 0.0
      ? devicePixelRatio
      : 1.0;

  @override
  bool shouldRepaint(covariant DesktopWindowFramePainter oldDelegate) {
    return windowId != oldDelegate.windowId ||
        devicePixelRatio != oldDelegate.devicePixelRatio ||
        radius != oldDelegate.radius ||
        frameColor != oldDelegate.frameColor ||
        borderColor != oldDelegate.borderColor;
  }
}

void _paintRoundedFrame(
  Canvas canvas,
  Rect frame, {
  required double radius,
  required double frameThickness,
  required double borderThickness,
  required double devicePixelRatio,
  required Color frameColor,
  required Color? borderColor,
}) {
  final geometry = desktopRoundedFrameGeometry(
    size: frame.size,
    radius: radius,
    frameThickness: frameThickness,
    borderThickness: borderThickness,
    devicePixelRatio: devicePixelRatio,
  );
  if (geometry.frameThickness <= 0.0) {
    return;
  }

  final compositeBorderColor = borderColor == null
      ? frameColor
      : Color.alphaBlend(borderColor, frameColor);
  if (geometry.outerRadius <= 0.0) {
    _paintSquareFrame(
      canvas,
      frame,
      frameThickness: geometry.frameThickness,
      color: compositeBorderColor,
    );
    return;
  }

  _paintFrameStrips(
    canvas,
    frame,
    radius: geometry.outerRadius,
    frameThickness: geometry.frameThickness,
    edgeHalfWidth: geometry.edgeHalfWidth,
    color: compositeBorderColor,
  );
  _paintFrameCorners(
    canvas,
    frame,
    geometry: geometry,
    color: compositeBorderColor,
  );
}

void _paintSquareFrame(
  Canvas canvas,
  Rect frame, {
  required double frameThickness,
  required Color color,
}) {
  canvas.drawDRRect(
    RRect.fromRectAndRadius(frame, Radius.zero),
    RRect.fromRectAndRadius(frame.deflate(frameThickness), Radius.zero),
    Paint()..color = color,
  );
}

void _paintFrameStrips(
  Canvas canvas,
  Rect frame, {
  required double radius,
  required double frameThickness,
  required double edgeHalfWidth,
  required Color color,
}) {
  final horizontalExtent = Rect.fromLTRB(
    frame.left + radius,
    frame.top,
    frame.right - radius,
    frame.bottom,
  );
  final verticalExtent = Rect.fromLTRB(
    frame.left,
    frame.top + radius,
    frame.right,
    frame.bottom - radius,
  );
  _paintFrameStrip(
    canvas,
    Rect.fromLTRB(
      horizontalExtent.left,
      frame.top - edgeHalfWidth,
      horizontalExtent.right,
      frame.top + frameThickness + edgeHalfWidth,
    ),
    shaderStart: Offset(0, frame.top - edgeHalfWidth),
    shaderEnd: Offset(0, frame.top + frameThickness + edgeHalfWidth),
    frameThickness: frameThickness,
    edgeHalfWidth: edgeHalfWidth,
    color: color,
  );
  _paintFrameStrip(
    canvas,
    Rect.fromLTRB(
      horizontalExtent.left,
      frame.bottom - frameThickness - edgeHalfWidth,
      horizontalExtent.right,
      frame.bottom + edgeHalfWidth,
    ),
    shaderStart: Offset(0, frame.bottom - frameThickness - edgeHalfWidth),
    shaderEnd: Offset(0, frame.bottom + edgeHalfWidth),
    frameThickness: frameThickness,
    edgeHalfWidth: edgeHalfWidth,
    color: color,
  );
  _paintFrameStrip(
    canvas,
    Rect.fromLTRB(
      frame.left - edgeHalfWidth,
      verticalExtent.top,
      frame.left + frameThickness + edgeHalfWidth,
      verticalExtent.bottom,
    ),
    shaderStart: Offset(frame.left - edgeHalfWidth, 0),
    shaderEnd: Offset(frame.left + frameThickness + edgeHalfWidth, 0),
    frameThickness: frameThickness,
    edgeHalfWidth: edgeHalfWidth,
    color: color,
  );
  _paintFrameStrip(
    canvas,
    Rect.fromLTRB(
      frame.right - frameThickness - edgeHalfWidth,
      verticalExtent.top,
      frame.right + edgeHalfWidth,
      verticalExtent.bottom,
    ),
    shaderStart: Offset(frame.right - frameThickness - edgeHalfWidth, 0),
    shaderEnd: Offset(frame.right + edgeHalfWidth, 0),
    frameThickness: frameThickness,
    edgeHalfWidth: edgeHalfWidth,
    color: color,
  );
}

void _paintFrameStrip(
  Canvas canvas,
  Rect rect, {
  required Offset shaderStart,
  required Offset shaderEnd,
  required double frameThickness,
  required double edgeHalfWidth,
  required Color color,
}) {
  if (rect.isEmpty) {
    return;
  }
  final extent = frameThickness + 2.0 * edgeHalfWidth;
  final innerRampStart = 2.0 * edgeHalfWidth / extent;
  final innerRampEnd = frameThickness / extent;
  canvas.drawRect(
    rect,
    Paint()
      ..isAntiAlias = false
      ..shader = ui.Gradient.linear(
        shaderStart,
        shaderEnd,
        <Color>[
          color.withValues(alpha: 0.0),
          color,
          color,
          color.withValues(alpha: 0.0),
        ],
        <double>[0.0, innerRampStart, innerRampEnd, 1.0],
      ),
  );
}

void _paintFrameCorners(
  Canvas canvas,
  Rect frame, {
  required DesktopRoundedFrameGeometry geometry,
  required Color color,
}) {
  final centers = <Offset>[
    Offset(frame.left + geometry.outerRadius, frame.top + geometry.outerRadius),
    Offset(
      frame.right - geometry.outerRadius,
      frame.top + geometry.outerRadius,
    ),
    Offset(
      frame.right - geometry.outerRadius,
      frame.bottom - geometry.outerRadius,
    ),
    Offset(
      frame.left + geometry.outerRadius,
      frame.bottom - geometry.outerRadius,
    ),
  ];
  final fringe = geometry.edgeHalfWidth;
  final cornerRects = <Rect>[
    Rect.fromLTRB(
      frame.left - fringe,
      frame.top - fringe,
      centers[0].dx,
      centers[0].dy,
    ),
    Rect.fromLTRB(
      centers[1].dx,
      frame.top - fringe,
      frame.right + fringe,
      centers[1].dy,
    ),
    Rect.fromLTRB(
      centers[2].dx,
      centers[2].dy,
      frame.right + fringe,
      frame.bottom + fringe,
    ),
    Rect.fromLTRB(
      frame.left - fringe,
      centers[3].dy,
      centers[3].dx,
      frame.bottom + fringe,
    ),
  ];
  final profile = _frameCornerProfile(geometry, color: color);
  final paint = Paint()..isAntiAlias = false;
  for (var index = 0; index < centers.length; index++) {
    paint.shader = ui.Gradient.radial(
      centers[index],
      geometry.shaderRadius,
      profile.colors,
      profile.stops,
    );
    canvas.drawRect(cornerRects[index], paint);
  }
}

({List<Color> colors, List<double> stops}) _frameCornerProfile(
  DesktopRoundedFrameGeometry geometry, {
  required Color color,
}) {
  final transparent = color.withValues(alpha: 0.0);
  final shaderRadius = geometry.shaderRadius;
  final innerStart = math.max(
    0.0,
    geometry.innerRadius - geometry.edgeHalfWidth,
  );
  final innerEnd = geometry.innerRadius + geometry.edgeHalfWidth;
  final outerStart = math.max(
    innerEnd,
    geometry.outerRadius - geometry.edgeHalfWidth,
  );
  final fillsCenter = geometry.innerRadius <= 0.0;

  return (
    colors: <Color>[
      fillsCenter ? color : transparent,
      color,
      color,
      transparent,
    ],
    stops: <double>[
      innerStart / shaderRadius,
      innerEnd / shaderRadius,
      outerStart / shaderRadius,
      1.0,
    ],
  );
}
