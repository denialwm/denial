import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'desktop_window_render_telemetry.dart';
import 'desktop_workspace.dart';

/// Keeps the static server-side decoration isolated from the live client
/// texture and from the stateful focus border.
///
/// Only the shadow/frame picture is marked complex. Applying the hint to a
/// single [CustomPaint] with both a background and foreground painter would
/// also force a full-window cache for the inexpensive focus border.
class DesktopWindowFrameLayers extends StatelessWidget {
  const DesktopWindowFrameLayers({
    required this.windowId,
    required this.borderPainter,
    required this.child,
    super.key,
  });

  final int windowId;
  final CustomPainter borderPainter;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        RepaintBoundary(
          child: IgnorePointer(
            child: CustomPaint(
              painter: DesktopWindowFramePainter(
                windowId: windowId,
                radius: ShellTheme.of(context).windowRadius,
              ),
              isComplex: true,
              willChange: false,
            ),
          ),
        ),
        child,
        IgnorePointer(child: CustomPaint(painter: borderPainter)),
      ],
    );
  }
}

/// Paints the shadow and opaque frame ring around a decorated client surface.
///
/// The center is deliberately left clear so client-provided per-pixel alpha is
/// preserved instead of being composited over a shell-owned window backdrop.
class DesktopWindowFramePainter extends CustomPainter {
  const DesktopWindowFramePainter({
    this.windowId = 0,
    this.radius = ShellRadii.window,
  });

  final int windowId;
  final double radius;

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
        RRect.fromRectAndRadius(shadowRect, Radius.circular(radius + 2)),
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
        Radius.circular(math.max(0.0, radius - DesktopMetrics.frameBorder)),
      ),
      Paint()..color = ShellColors.windowFrameSurface,
    );
  }

  @override
  bool shouldRepaint(covariant DesktopWindowFramePainter oldDelegate) {
    return windowId != oldDelegate.windowId || radius != oldDelegate.radius;
  }
}
