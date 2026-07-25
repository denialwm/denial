import 'package:flutter/widgets.dart';

String formatOpaqueColorHex(Color color) {
  int byte(double component) {
    return (component * 255.0).round().clamp(0, 255);
  }

  final value = (byte(color.r) << 16) | (byte(color.g) << 8) | byte(color.b);
  return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
