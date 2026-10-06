import 'package:flutter/widgets.dart';

({int red, int green, int blue}) opaqueColorRgb(Color color) {
  int byte(double component) {
    return (component * 255.0).round().clamp(0, 255);
  }

  return (red: byte(color.r), green: byte(color.g), blue: byte(color.b));
}

String formatOpaqueColorHex(Color color) {
  final rgb = opaqueColorRgb(color);
  final value = (rgb.red << 16) | (rgb.green << 8) | rgb.blue;
  return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// Parses an opaque three- or six-digit hexadecimal color.
///
/// A leading `#` or `0x` is optional. Three-digit values use the CSS shorthand
/// expansion (`#3AF` becomes `#33AAFF`). Alpha is deliberately unsupported:
/// shell accent colors are always opaque.
Color? parseOpaqueColorHex(String input) {
  var value = input.trim();
  if (value.startsWith('#')) {
    value = value.substring(1);
  } else if (value.toLowerCase().startsWith('0x')) {
    value = value.substring(2);
  }
  if (!RegExp(r'^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(value)) {
    return null;
  }
  if (value.length == 3) {
    value = value.split('').map((digit) => '$digit$digit').join();
  }
  return Color(0xff000000 | int.parse(value, radix: 16));
}
