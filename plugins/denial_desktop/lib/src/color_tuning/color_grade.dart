import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// One of the grade's scalar controls, with the range deniald accepts.
enum GradeSlider {
  exposure(3),
  contrast(1.5),
  saturation(1),
  vibrance(1),
  temperature(1),
  tint(1);

  const GradeSlider(this.range);

  /// The control spans -range..range; zero is neutral.
  final double range;
}

/// One of the three color wheels. Its puck is a chroma push, its ring a
/// level for all three channels.
enum GradeWheel {
  /// Shadows.
  lift(chroma: 0.12, level: 0.12),

  /// Midtones.
  gamma(chroma: 0.5, level: 0.75),

  /// Highlights.
  gain(chroma: 0.5, level: 0.75);

  const GradeWheel({required this.chroma, required this.level});

  /// The channel push at the rim.
  final double chroma;

  /// The level at either end of the ring.
  final double level;
}

/// A wheel's position: [puck] inside the unit disc, [level] in -1..1.
@immutable
class WheelPosition {
  const WheelPosition(this.puck, this.level);

  static const WheelPosition neutral = WheelPosition(Offset.zero, 0);

  final Offset puck;
  final double level;

  @override
  bool operator ==(Object other) =>
      other is WheelPosition && other.puck == puck && other.level == level;

  @override
  int get hashCode => Object.hash(puck, level);
}

/// The hue each channel sits at on a wheel, in radians from the top,
/// clockwise: red at the top, as the wheel is painted.
const List<double> _channelHues = <double>[0, 2 * math.pi / 3, 4 * math.pi / 3];

/// The puck's hue: zero at the top, clockwise.
double wheelHue(Offset puck) => math.atan2(puck.dx, -puck.dy);

/// The tuning editor's grade, as deniald's `color.grade.*` methods carry it.
/// All zero is neutral.
@immutable
class ColorGrade {
  const ColorGrade({
    this.sliders = const <GradeSlider, double>{},
    this.wheels = const <GradeWheel, WheelPosition>{},
  });

  static const ColorGrade neutral = ColorGrade();

  final Map<GradeSlider, double> sliders;
  final Map<GradeWheel, WheelPosition> wheels;

  double slider(GradeSlider slider) => sliders[slider] ?? 0;

  WheelPosition wheel(GradeWheel wheel) =>
      wheels[wheel] ?? WheelPosition.neutral;

  bool get isNeutral =>
      sliders.values.every((value) => value == 0) &&
      wheels.values.every((position) => position == WheelPosition.neutral);

  ColorGrade withSlider(GradeSlider slider, double value) => ColorGrade(
    sliders: <GradeSlider, double>{
      ...sliders,
      slider: value.clamp(-slider.range, slider.range),
    },
    wheels: wheels,
  );

  ColorGrade withWheel(GradeWheel wheel, WheelPosition position) {
    final distance = position.puck.distance;
    return ColorGrade(
      sliders: sliders,
      wheels: <GradeWheel, WheelPosition>{
        ...wheels,
        wheel: WheelPosition(
          distance > 1 ? position.puck / distance : position.puck,
          position.level.clamp(-1.0, 1.0),
        ),
      },
    );
  }

  /// The wheel's three channel values: the puck pushes towards its hue and
  /// away from the opposite one, without moving the level.
  static List<double> _channels(GradeWheel wheel, WheelPosition position) {
    final amount = position.puck.distance;
    final hue = wheelHue(position.puck);
    return <double>[
      for (final channelHue in _channelHues)
        wheel.chroma * amount * math.cos(hue - channelHue) +
            wheel.level * position.level,
    ];
  }

  static WheelPosition _position(GradeWheel wheel, List<double> channels) {
    final mean = channels.reduce((a, b) => a + b) / 3;
    var x = 0.0;
    var y = 0.0;
    for (var c = 0; c < 3; c++) {
      final push = channels[c] - mean;
      x += push * math.sin(_channelHues[c]);
      y -= push * math.cos(_channelHues[c]);
    }
    final puck = Offset(x, y) * (2 / 3) / wheel.chroma;
    final distance = puck.distance;
    return WheelPosition(
      distance > 1 ? puck / distance : puck,
      (mean / wheel.level).clamp(-1.0, 1.0),
    );
  }

  /// Pucks stay in the disc and levels in -1..1, so every channel is within
  /// the wheel's chroma plus level, inside deniald's ranges.
  Map<String, Object> toJson() {
    double round(double value) => (value * 1e4).round() / 1e4;
    return <String, Object>{
      for (final slider in GradeSlider.values)
        slider.name: round(this.slider(slider)),
      for (final wheel in GradeWheel.values)
        wheel.name: <double>[
          for (final value in _channels(wheel, this.wheel(wheel))) round(value),
        ],
    };
  }

  factory ColorGrade.fromJson(Object? json) {
    if (json is! Map) return neutral;
    double number(Object? value) => value is num ? value.toDouble() : 0;
    return ColorGrade(
      sliders: <GradeSlider, double>{
        for (final slider in GradeSlider.values)
          slider: number(json[slider.name]).clamp(-slider.range, slider.range),
      },
      wheels: <GradeWheel, WheelPosition>{
        for (final wheel in GradeWheel.values)
          wheel: switch (json[wheel.name]) {
            final List<Object?> rgb when rgb.length == 3 => _position(
              wheel,
              rgb.map(number).toList(growable: false),
            ),
            _ => WheelPosition.neutral,
          },
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ColorGrade &&
      GradeSlider.values.every((s) => slider(s) == other.slider(s)) &&
      GradeWheel.values.every((w) => wheel(w) == other.wheel(w));

  @override
  int get hashCode => Object.hashAll(<Object>[
    for (final s in GradeSlider.values) slider(s),
    for (final w in GradeWheel.values) wheel(w),
  ]);
}
