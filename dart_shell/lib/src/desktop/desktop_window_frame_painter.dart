import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'desktop_workspace.dart';

/// Paints the shadow and opaque frame ring around a decorated client surface.
///
/// The center is deliberately left clear so client-provided per-pixel alpha is
/// preserved instead of being composited over a shell-owned window backdrop.
class DesktopWindowFramePainter extends CustomPainter {
  const DesktopWindowFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    final frame = Offset.zero & size;
    final frameShape = RRect.fromRectAndRadius(
      frame,
      const Radius.circular(ShellRadii.window),
    );
    final outsideFrame = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(frame.inflate(64))
      ..addRRect(frameShape);
    final shadowRect = frame.shift(const Offset(0, 12)).inflate(2);
    final shadowPaint = Paint()
      ..color = ShellColors.shadow
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16.5);

    canvas
      ..save()
      ..clipPath(outsideFrame)
      ..drawRRect(
        RRect.fromRectAndRadius(
          shadowRect,
          const Radius.circular(ShellRadii.window + 2),
        ),
        shadowPaint,
      )
      ..restore();

    final innerFrame = frame.deflate(DesktopMetrics.frameBorder);
    if (innerFrame.isEmpty) {
      canvas.drawRRect(
        frameShape,
        Paint()..color = ShellColors.windowFrameSurface,
      );
      return;
    }

    canvas.drawDRRect(
      frameShape,
      RRect.fromRectAndRadius(
        innerFrame,
        Radius.circular(
          math.max(
            0.0,
            ShellRadii.window - DesktopMetrics.frameBorder,
          ),
        ),
      ),
      Paint()..color = ShellColors.windowFrameSurface,
    );
  }

  @override
  bool shouldRepaint(covariant DesktopWindowFramePainter oldDelegate) => false;
}
