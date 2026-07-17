import 'package:flutter/material.dart';

class HomeBackdropPainter extends CustomPainter {
  const HomeBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = const Color(0x14000000);
    canvas.drawRect(Offset.zero & size, scrim);
  }

  @override
  bool shouldRepaint(covariant HomeBackdropPainter oldDelegate) {
    return false;
  }
}
