import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/shell_theme.dart';

import 'liquid/liquid.dart';

/// How a swipe on the pill ended, for the liquid.
enum PillRelease {
  /// Nothing happened: the bar sags back.
  settle,

  /// Home, recents or another app: the bar is flung the way the finger
  /// went and wobbles back.
  launch,
}

/// The home pill as a lazy bar of water. A touch sends a ripple along it
/// and gathers its water under the finger, thinning the ends. A drag pulls
/// the bar into a soft hump toward the finger, late, on loose springs, as
/// if it could not be bothered; letting go, it sags back and wobbles for a
/// while. The water turns to the accent as the swipe nears doing
/// something. At rest it is the plain pill and nothing ticks.
///
/// Only how the pill looks: the gesture is the handle's.
class PillLiquid extends ChangeNotifier {
  PillLiquid(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  static const double restWidth = 116;
  static const double restThickness = 5;

  /// How much water gathers under a finger, and how much the rest of the
  /// bar thins for it, in pixels of half thickness.
  static const double _gather = 3;
  static const double _drain = 1.2;

  /// How far the hump reaches toward the finger, with rubber.
  static const double _reach = 26;

  /// How wide the hump is along the bar.
  static const double _humpWidth = 30;

  /// The fastest the bar ever moves, in pixels per second: a fling gets
  /// the same lazy pace as a slow drag, which never reaches it.
  static const double _laziness = 120;

  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _time = 0;
  bool reduced = false;

  // Loose and late: every part of the bar takes its time and overshoots.
  final LiquidSpring _swell = LiquidSpring(
    0,
    stiffness: 120,
    dampingRatio: 0.2,
  );
  final LiquidSpring _tilt = LiquidSpring(0, stiffness: 70, dampingRatio: 0.12);
  final LiquidSpring _bendX = LiquidSpring(
    0,
    stiffness: 70,
    dampingRatio: 0.24,
  );
  final LiquidSpring _bendY = LiquidSpring(
    0,
    stiffness: 70,
    dampingRatio: 0.24,
  );
  final LiquidSpring _accent = LiquidSpring(
    0,
    stiffness: 260,
    dampingRatio: 0.9,
  );

  bool _touching = false;
  bool _armed = false;
  double _anchor = 0;
  double _fingerSpeed = 0;
  final List<_Ripple> _ripples = [];

  /// A finger landed [x] pixels from the pill's middle.
  void touch(double x) {
    _touching = true;
    _anchor = x.clamp(-restWidth / 2, restWidth / 2).toDouble();
    _swell.target = 1;
    _ripples.add(_Ripple(_anchor, _time, 2.2));
    _start();
  }

  /// The finger is [travel] from where it landed, moving sideways at
  /// [speed] pixels per second. The hump chases it; it never jumps there.
  void drag(Offset travel, double speed) {
    _fingerSpeed = speed;
    final distance = travel.distance;
    final pull = distance <= 0
        ? Offset.zero
        : travel / distance * LiquidTuning.rubber(distance, reach: _reach);
    _bendX.target = pull.dx;
    _bendY.target = pull.dy;
    _start();
  }

  /// How close the swipe is to doing something, 0 to 1, and whether it
  /// would.
  void arm(double progress, {required bool armed}) {
    final next = armed ? 1.0 : progress.clamp(0.0, 0.85).toDouble();
    if (next == _accent.target) return;
    if (armed && !_armed) {
      // Arming runs a lazy pulse along the pill.
      _ripples.add(_Ripple(_anchor, _time, 1.6));
    }
    _armed = armed;
    _accent.target = next;
    _start();
  }

  void release(PillRelease how, {Offset velocity = Offset.zero}) {
    if (!_touching) return;
    _touching = false;
    _fingerSpeed = 0;
    if (how == PillRelease.launch) {
      // Flung the way the finger went, then it wobbles home.
      final kick = velocity * 0.04;
      _bendX.velocity += kick.dx.clamp(-_laziness, _laziness);
      _bendY.velocity += kick.dy.clamp(-_laziness, _laziness);
      _ripples.add(_Ripple(_anchor, _time, 2.6));
    } else {
      _ripples.add(_Ripple(_anchor, _time, 1.2));
    }
    _bendX.target = 0;
    _bendY.target = 0;
    _swell.target = 0;
    _accent.target = 0;
    _armed = false;
    _start();
  }

  List<LiquidSpring> get _springs => [_swell, _tilt, _bendX, _bendY, _accent];

  void _start() {
    if (reduced) {
      for (final spring in _springs) {
        spring.settle();
      }
      _tilt.set(0);
      _bendX.set(0);
      _bendY.set(0);
      _ripples.clear();
      notifyListeners();
      return;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 120
        : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    _last = elapsed;
    _time += dt;
    // The water lags the finger, and the bar's own swing: moving right,
    // it piles up on the left.
    final swing = _fingerSpeed + _bendX.velocity * 2;
    _tilt.target = (swing * 0.004).clamp(-1.0, 1.0) * 1.6;
    if (_touching) _fingerSpeed *= LiquidTuning.fingerDecay(dt);
    for (final spring in _springs) {
      spring.step(dt);
    }
    final speed = math.sqrt(
      _bendX.velocity * _bendX.velocity + _bendY.velocity * _bendY.velocity,
    );
    if (speed > _laziness) {
      _bendX.velocity *= _laziness / speed;
      _bendY.velocity *= _laziness / speed;
    }
    _ripples.removeWhere((ripple) => _time - ripple.start > 1.4);
    notifyListeners();
    final resting =
        !_touching &&
        _ripples.isEmpty &&
        _swell.resting(0.001) &&
        _tilt.resting(0.02) &&
        _bendX.resting(0.05) &&
        _bendY.resting(0.05) &&
        _accent.resting(0.001);
    if (resting) {
      for (final spring in _springs) {
        spring.settle();
      }
      _ticker.stop();
      notifyListeners();
    }
  }

  double get accent => _accent.value.clamp(0.0, 1.0).toDouble();

  /// Half the bar's thickness at [x]: water gathered under the finger,
  /// piled up against the swing, its surface shivering while it moves.
  double radiusAt(double x) {
    final d = (x - _anchor) / _humpWidth;
    final gathered = math.exp(-d * d / 2);
    final lean = -_tilt.value * x / (restWidth / 2);
    final shiver =
        0.35 * math.sin(x / 7 + _time * 8) * _swell.value.abs().clamp(0, 1);
    return math.max(
      0.8,
      restThickness / 2 +
          _swell.value * (_gather * gathered - _drain) +
          lean +
          shiver +
          rippleAt(x),
    );
  }

  /// The bar's middle line at [x]: lifted and dragged sideways around
  /// where the finger holds it.
  Offset centreAt(double x) {
    final d = (x - _anchor) / _humpWidth;
    final hump = math.exp(-d * d / 2);
    return Offset(x + _bendX.value * 0.35 * hump, _bendY.value * hump);
  }

  /// How far the bar's outline is pushed out at [x] by ripples running
  /// from where they started.
  double rippleAt(double x) {
    var offset = 0.0;
    for (final ripple in _ripples) {
      final age = _time - ripple.start;
      final strength = ripple.amplitude * math.exp(-age * 2.6);
      final travel = 110 * age;
      for (final front in [ripple.x - travel, ripple.x + travel]) {
        final d = (x - front) / 12;
        offset += strength * math.exp(-d * d / 2);
      }
    }
    return offset;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _Ripple {
  _Ripple(this.x, this.start, this.amplitude);

  final double x;
  final double start;
  final double amplitude;
}

/// Paints [liquid] as the home pill, centred in a box the pill's size.
class LiquidPill extends StatelessWidget {
  const LiquidPill({super.key, required this.liquid});

  final PillLiquid liquid;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    return SizedBox(
      width: PillLiquid.restWidth,
      height: PillLiquid.restThickness,
      child: CustomPaint(
        painter: _LiquidPillPainter(
          liquid,
          body: context.shellColors.gesturePill,
          accent: theme.accent,
        ),
      ),
    );
  }
}

class _LiquidPillPainter extends CustomPainter {
  _LiquidPillPainter(this.liquid, {required this.body, required this.accent})
    : super(repaint: liquid);

  final PillLiquid liquid;
  final Color body;
  final Color accent;

  static const int _steps = 48;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.drawPath(
      _body(PillLiquid.restWidth),
      Paint()..color = Color.lerp(body, accent, liquid.accent)!,
    );
    canvas.restore();
  }

  /// The water's outline around its bent middle line, its round ends kept.
  Path _body(double width) {
    final half = width / 2;
    final top = <Offset>[];
    final bottom = <Offset>[];
    for (var i = 0; i <= _steps; i += 1) {
      final x = -half + width * i / _steps;
      final radius = liquid.radiusAt(x);
      final end = (x.abs() - (half - radius)) / radius;
      final round = end <= 0 ? 1.0 : math.sqrt(math.max(0.0, 1 - end * end));
      final h = radius * round;
      final centre = liquid.centreAt(x);
      top.add(centre - Offset(0, h));
      bottom.add(centre + Offset(0, h));
    }
    final path = Path()..moveTo(top.first.dx, top.first.dy);
    for (final point in top.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    for (final point in bottom.reversed) {
      path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_LiquidPillPainter oldDelegate) =>
      oldDelegate.liquid != liquid ||
      oldDelegate.body != body ||
      oldDelegate.accent != accent;
}
