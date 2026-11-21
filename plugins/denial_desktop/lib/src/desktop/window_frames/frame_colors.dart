import 'package:flutter/widgets.dart';

/// The frame's neutral colours, by the shell's brightness and whether the
/// window has the keyboard.
@immutable
final class WindowFrameColors {
  const WindowFrameColors({
    required this.bar,
    required this.border,
    required this.text,
    required this.hover,
    required this.pressed,
  });

  factory WindowFrameColors.of(Brightness brightness, {required bool active}) {
    return switch ((brightness, active)) {
      (Brightness.dark, true) => _darkActive,
      (Brightness.dark, false) => _darkInactive,
      (Brightness.light, true) => _lightActive,
      (Brightness.light, false) => _lightInactive,
    };
  }

  static const _darkActive = WindowFrameColors(
    bar: Color(0xff202020),
    border: Color(0xff5a5a5a),
    text: Color(0xffffffff),
    hover: Color(0x1affffff),
    pressed: Color(0x0fffffff),
  );
  static const _darkInactive = WindowFrameColors(
    bar: Color(0xff2b2b2b),
    border: Color(0xff3a3a3a),
    text: Color(0xff9d9d9d),
    hover: Color(0x1affffff),
    pressed: Color(0x0fffffff),
  );
  static const _lightActive = WindowFrameColors(
    bar: Color(0xfff3f3f3),
    border: Color(0xff8c8c8c),
    text: Color(0xff000000),
    hover: Color(0x14000000),
    pressed: Color(0x0a000000),
  );
  static const _lightInactive = WindowFrameColors(
    bar: Color(0xfff9f9f9),
    border: Color(0xffc4c4c4),
    text: Color(0xff8a8a8a),
    hover: Color(0x14000000),
    pressed: Color(0x0a000000),
  );

  /// The close button under the pointer, in both brightnesses.
  static const closeHover = Color(0xffc42b1c);
  static const closePressed = Color(0xffb3271a);
  static const closeGlyph = Color(0xffffffff);

  final Color bar;
  final Color border;

  /// The title and the caption glyphs.
  final Color text;

  /// Laid over [bar] under a hovered or pressed button.
  final Color hover;
  final Color pressed;
}
