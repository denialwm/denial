import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/tokens.dart';

/// The scrim behind the home content. It fades with that content, so home
/// coming back under recents or the shade does not darken them at once.
class HomeBackdropPainter extends CustomPainter {
  const HomeBackdropPainter({this.opacity}) : super(repaint: opacity);

  final Animation<double>? opacity;

  @override
  void paint(Canvas canvas, Size size) {
    const color = ShellMediaColors.wallpaperScrim;
    final alpha = color.a * (opacity?.value ?? 1);
    if (alpha <= 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(covariant HomeBackdropPainter oldDelegate) {
    return opacity != oldDelegate.opacity;
  }
}
