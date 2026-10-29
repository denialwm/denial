import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

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

  /// Whether [other] grades the same, once both went through deniald's
  /// rounding.
  bool matches(ColorGrade other) {
    final mine = toJson();
    final theirs = other.toJson();
    double distance(Object? a, Object? b) => switch ((a, b)) {
      (final double a, final double b) => (a - b).abs(),
      (final List<double> a, final List<double> b) => [
        for (var c = 0; c < 3; c++) (a[c] - b[c]).abs(),
      ].reduce(math.max),
      _ => double.infinity,
    };
    return mine.keys.every((key) => distance(mine[key], theirs[key]) < 1e-3);
  }

  /// [color] through the grade, as deniald bakes it (`color_grade.rs`),
  /// without the target's base look. For previews.
  Color preview(Color color) {
    double decode(double v) => math.pow(math.max(v, 0), 2.2).toDouble();
    double encode(double v) => math.pow(math.max(v, 0), 1 / 2.2).toDouble();
    double exp2(double v) => math.pow(2, v).toDouble();
    final temperature = slider(GradeSlider.temperature);
    final tint = slider(GradeSlider.tint);
    final balance = <double>[
      exp2(0.25 * temperature),
      exp2(-0.2 * tint),
      exp2(-0.25 * temperature),
    ];
    final balanceLuma =
        0.2126 * balance[0] + 0.7152 * balance[1] + 0.0722 * balance[2];
    final exposure = exp2(slider(GradeSlider.exposure));
    final slope = exp2(slider(GradeSlider.contrast));
    final lift = _channels(GradeWheel.lift, wheel(GradeWheel.lift));
    final gamma = _channels(GradeWheel.gamma, wheel(GradeWheel.gamma));
    final gain = _channels(GradeWheel.gain, wheel(GradeWheel.gain));
    final input = <double>[color.r, color.g, color.b];
    final light = <double>[
      for (var c = 0; c < 3; c++)
        () {
          var v = math.min(
            encode(decode(input[c]) * balance[c] / balanceLuma * exposure),
            1.0,
          );
          v = _contrastCurve(v, slope);
          final lifted = v + lift[c] * (1 - v);
          return decode(
            math
                .pow(math.max(lifted * exp2(gain[c]), 0), exp2(-gamma[c]))
                .toDouble(),
          );
        }(),
    ];
    final luma = 0.2126 * light[0] + 0.7152 * light[1] + 0.0722 * light[2];
    final high = light.reduce(math.max);
    final low = light.reduce(math.min);
    final chroma = high > 0 ? (high - low) / high : 0.0;
    final factor =
        (1 + slider(GradeSlider.saturation)) *
        math.max(1 + slider(GradeSlider.vibrance) * (1 - chroma), 0);
    final out = [
      for (final v in light) math.min(encode(luma + (v - luma) * factor), 1.0),
    ];
    return Color.from(alpha: color.a, red: out[0], green: out[1], blue: out[2]);
  }

  /// Middle grey, encoded: the contrast pivot.
  static const double _pivot = 0.4587;

  static double _contrastCurve(double v, double slope) => v <= _pivot
      ? _pivot * math.pow(v / _pivot, slope)
      : 1 - (1 - _pivot) * math.pow((1 - v) / (1 - _pivot), slope);

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
