import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Shared pieces of the liquid motion recipe, `docs/LIQUID_MOTION.md`.

/// A damped spring stepped by the frame clock. Values are free to overshoot.
class LiquidSpring {
  LiquidSpring(
    this.value, {
    required this.stiffness,
    required this.dampingRatio,
  }) : target = value;

  double value;
  double target;
  double velocity = 0;
  double stiffness;
  double dampingRatio;

  void set(double next) {
    value = next;
    target = next;
    velocity = 0;
  }

  void tune(double stiffness, double dampingRatio) {
    this.stiffness = stiffness;
    this.dampingRatio = dampingRatio;
  }

  void step(double dt) {
    // Semi-implicit Euler in sub-steps stays stable for stiff springs at
    // any frame rate.
    final damping = 2 * dampingRatio * math.sqrt(stiffness);
    var remaining = dt;
    while (remaining > 0) {
      final h = math.min(remaining, 1 / 480);
      velocity += (-stiffness * (value - target) - damping * velocity) * h;
      value += velocity * h;
      remaining -= h;
    }
  }

  bool resting(double tolerance) =>
      (value - target).abs() < tolerance && velocity.abs() < tolerance * 10;

  void settle() {
    value = target;
    velocity = 0;
  }
}

/// The springs of a liquid level, tuned as the recipe says.
abstract final class LiquidTuning {
  static LiquidSpring level(double value) =>
      LiquidSpring(value, stiffness: 300, dampingRatio: 0.8);

  /// The surface's bulge in logical pixels, upward positive.
  static LiquidSpring surface() =>
      LiquidSpring(0, stiffness: 340, dampingRatio: 0.2);

  /// Squash and stretch in logical pixels: positive reaches up.
  static LiquidSpring stretch() =>
      LiquidSpring(0, stiffness: 520, dampingRatio: 0.42);

  static LiquidSpring grab() =>
      LiquidSpring(0, stiffness: 620, dampingRatio: 0.82);

  /// The tug of one step toward its change, and of a step against an end.
  static const double stepKick = 240;
  static const double limitKick = 520;

  /// The surface leans with the level's speed, in pixels per second; rising,
  /// its middle leads.
  static double surfaceTarget(double pixelsPerSecond) =>
      (pixelsPerSecond * 0.05).clamp(-14.0, 14.0).toDouble();

  /// How far a body stretches when pulled [pull] pixels past its end.
  static double rubber(double pull, {double reach = 28}) =>
      pull.sign * reach * (1 - 1 / (1 + pull.abs() / 60));

  /// Blends a new finger speed into the old one, so the surface leans with
  /// the finger and not with each jitter of the touch samples.
  static double fingerVelocity(double previous, double sample) =>
      previous * 0.6 + sample * 0.4;

  /// How much finger speed is left after [dt] seconds of rest.
  static double fingerDecay(double dt) => math.pow(0.02, dt).toDouble();
}

/// The liquid's body in [size]: everything below the surface at [level]
/// (0 empty, 1 full). The surface bulges by [bulge] pixels and, while it
/// rings, tilts with a ripple at [time] seconds.
Path liquidFillPath(
  Size size, {
  required double level,
  required double bulge,
  required double time,
}) {
  final y = size.height * (1 - level);
  final ripple = (bulge.abs() * 0.4) * math.sin(time * 26);
  return Path()
    ..moveTo(0, y + ripple)
    ..cubicTo(
      size.width * 0.3,
      y - bulge,
      size.width * 0.7,
      y - bulge,
      size.width,
      y - ripple,
    )
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();
}

/// A smoothstep of [t] clamped to 0..1.
double liquidSmooth(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/// The springs of one control and the one ticker that steps them. The
/// ticker starts on any event and stops itself once every spring rests.
abstract class LiquidMotion extends ChangeNotifier {
  LiquidMotion(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  Duration? _last;

  /// Every spring, for reduced motion and for the settle at rest.
  List<LiquidSpring> get springs;

  /// Steps the springs by [dt] seconds; true once everything rests.
  bool advance(double dt);

  /// Called once the motion has come to rest.
  void rested() {}

  /// Starts the ticker, or with reduced motion settles at once.
  void kick({required bool reduceMotion}) {
    if (reduceMotion) {
      _settle();
      notifyListeners();
      rested();
      return;
    }
    if (!_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    final dt = last == null
        ? 1 / 120
        : ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    final resting = advance(dt);
    if (resting) {
      _settle();
      _ticker.stop();
    }
    notifyListeners();
    if (resting) rested();
  }

  void _settle() {
    for (final spring in springs) {
      spring.settle();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
