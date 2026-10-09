import 'dart:ui' as ui;

import 'package:denial_flutter_sdk/pets.dart';
import 'package:flutter/widgets.dart';

import 'contact.dart';

/// A held pet's contact shadow: its own shape, dark and soft, a little below
/// it, where it touches its window ([contactFade]). The host clips it to the
/// window.
class ContactShadow extends StatelessWidget {
  const ContactShadow({
    super.key,
    required this.shadow,
    required this.fade,
    required this.drop,
    required this.softness,
  });

  final PetShadow shadow;
  final ContactFade fade;

  /// How far below the pet it falls, in logical pixels.
  final double drop;

  /// How soft it is, as a blur's sigma in logical pixels.
  final double softness;

  /// How dark it is where the pet touches the window.
  static const strength = 0.9;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (_) => _mask(fade),
      child: Transform.translate(
        offset: Offset(0, drop),
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: softness,
            sigmaY: softness,
            tileMode: TileMode.decal,
          ),
          child: ColorFiltered(
            colorFilter: const ColorFilter.mode(
              Color.fromRGBO(0, 0, 0, strength),
              BlendMode.srcIn,
            ),
            child: shadow.surface,
          ),
        ),
      ),
    );
  }

  static Shader _mask(ContactFade fade) {
    const full = Color(0xFFFFFFFF);
    const none = Color(0x00FFFFFF);
    Offset at(ContactPoint point) => Offset(point.x, point.y);
    return switch (fade) {
      AcrossEdge(:final from, :final to) => ui.Gradient.linear(
        at(from),
        at(to),
        const [none, full, none],
        const [0.0, 0.5, 1.0],
      ),
      AroundCorner(:final center, :final radius) => ui.Gradient.radial(
        at(center),
        radius,
        const [full, none],
      ),
    };
  }
}
