import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../widgets/liquid/liquid.dart';
import 'color_grade.dart';

/// A color wheel whose puck is a liquid bead: it stretches along its motion,
/// swells under the finger and, let go, settles with a wobble. The finger
/// drags it relative to where it went down; a double tap pours it home.
class LiquidColorWheel extends StatefulWidget {
  const LiquidColorWheel({
    super.key,
    required this.puck,
    required this.revision,
    required this.onChanged,
    required this.ink,
    required this.rim,
    this.semanticLabel,
  });

  /// Inside the unit disc.
  final Offset puck;
  final int revision;
  final void Function(Offset puck, {required bool save}) onChanged;
  final Color ink;
  final Color rim;
  final String? semanticLabel;

  @override
  State<LiquidColorWheel> createState() => _LiquidColorWheelState();
}

class _LiquidColorWheelState extends State<LiquidColorWheel>
    with SingleTickerProviderStateMixin {
  late final _WheelMotion _motion = _WheelMotion(this, widget.puck);
  int? _pointer;
  Offset _downLocal = Offset.zero;
  Offset _downPuck = Offset.zero;
  Offset _puck = Offset.zero;
  bool _moved = false;
  double _radius = 1;

  @override
  void initState() {
    super.initState();
    _puck = widget.puck;
  }

  @override
  void didUpdateWidget(covariant LiquidColorWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision && _pointer == null) {
      _puck = widget.puck;
      _motion.pourTo(_puck, reduceMotion: _reduceMotion);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downLocal = event.localPosition;
    _downPuck = _puck;
    _moved = false;
    _motion.hold(reduceMotion: _reduceMotion);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    // The rim is two radii of travel away: fine pushes need no precision.
    final wanted =
        _downPuck + (event.localPosition - _downLocal) / (_radius * 2);
    final distance = wanted.distance;
    final inside = distance > 1 ? wanted / distance : wanted;
    final pull = math.max(0.0, distance - 1) * _radius * 2;
    if (pull > 0 && _motion.pull == 0) HapticFeedback.selectionClick();
    _motion.follow(inside, wanted, pull, event.timeStamp, _reduceMotion);
    final next = _snap(inside);
    if (next != _puck) {
      _puck = next;
      _moved = true;
      widget.onChanged(_puck, save: false);
    }
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _motion.release(reduceMotion: _reduceMotion);
    if (_moved) widget.onChanged(_puck, save: true);
  }

  void _reset() {
    if (_puck == Offset.zero) return;
    _puck = Offset.zero;
    _motion.pourTo(Offset.zero, reduceMotion: _reduceMotion);
    widget.onChanged(Offset.zero, save: true);
  }

  /// The middle catches, so neutral is easy to find again.
  Offset _snap(Offset puck) {
    if (puck.distance < 0.025) return Offset.zero;
    return Offset(
      (puck.dx * 1000).round() / 1000,
      (puck.dy * 1000).round() / 1000,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      value:
          '${(wheelHue(_puck) * 180 / math.pi).round() % 360}°, '
          '${(_puck.distance * 100).round()}%',
      child: GestureDetector(
        onDoubleTap: _reset,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              _radius = math.max(1, side / 2 - 8);
              return CustomPaint(
                size: Size.square(side),
                foregroundPainter: _WheelPainter(
                  motion: _motion,
                  ink: widget.ink,
                  rim: widget.rim,
                ),
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: Size.square(side),
                    isComplex: true,
                    painter: _WheelDiscPainter(ink: widget.ink),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WheelMotion extends LiquidMotion {
  _WheelMotion(super.vsync, Offset puck)
    : x = LiquidTuning.level(puck.dx),
      y = LiquidTuning.level(puck.dy);
  final LiquidSpring x;
  final LiquidSpring y;

  /// The bead's stretch along its motion, in pixels, and its direction.
  final LiquidSpring stretch = LiquidTuning.stretch();
  double stretchAngle = 0;
  final LiquidSpring grab = LiquidTuning.grab();

  /// Rubber past the rim, in unit-disc lengths, toward [pullAngle].
  final LiquidSpring rubber = LiquidTuning.stretch();
  double pullAngle = 0;
  double pull = 0;
  Offset _fingerVelocity = Offset.zero;
  Duration? _lastSample;
  Offset _lastPuck = Offset.zero;
  bool _holding = false;

  Offset get puck => Offset(x.value, y.value);

  @override
  List<LiquidSpring> get springs => [x, y, stretch, grab, rubber];

  void hold({required bool reduceMotion}) {
    _holding = true;
    grab.target = 1;
    _fingerVelocity = Offset.zero;
    _lastSample = null;
    _lastPuck = puck;
    kick(reduceMotion: reduceMotion);
  }

  void follow(
    Offset inside,
    Offset wanted,
    double pullPixels,
    Duration at,
    bool reduceMotion,
  ) {
    final previous = _lastSample;
    if (previous != null) {
      final dt = (at - previous).inMicroseconds / 1e6;
      if (dt > 0) {
        final sample = (inside - _lastPuck) / dt;
        _fingerVelocity = Offset(
          LiquidTuning.fingerVelocity(_fingerVelocity.dx, sample.dx),
          LiquidTuning.fingerVelocity(_fingerVelocity.dy, sample.dy),
        );
      }
    }
    _lastSample = at;
    _lastPuck = inside;
    x.set(inside.dx);
    y.set(inside.dy);
    pull = pullPixels;
    pullAngle = wanted.direction;
    rubber.set(LiquidTuning.rubber(pullPixels, reach: 12));
    kick(reduceMotion: reduceMotion);
  }

  void release({required bool reduceMotion}) {
    _holding = false;
    grab.target = 0;
    pull = 0;
    rubber.target = 0;
    // Springs take over with the finger's speed.
    x.velocity = _fingerVelocity.dx;
    y.velocity = _fingerVelocity.dy;
    x.target = x.value;
    y.target = y.value;
    kick(reduceMotion: reduceMotion);
  }

  void pourTo(Offset puck, {required bool reduceMotion}) {
    x.target = puck.dx;
    y.target = puck.dy;
    kick(reduceMotion: reduceMotion);
  }

  @override
  bool advance(double dt) {
    final velocity = _holding
        ? _fingerVelocity
        : Offset(x.velocity, y.velocity);
    if (_holding) {
      _fingerVelocity *= LiquidTuning.fingerDecay(dt);
    } else {
      x.step(dt);
      y.step(dt);
      // Released with speed, the bead must stay on the wheel.
      final distance = puck.distance;
      if (distance > 1) {
        x.value /= distance;
        y.value /= distance;
        x.target = x.value;
        y.target = y.value;
        x.velocity *= -0.3;
        y.velocity *= -0.3;
      }
    }
    // The bead leans along its motion, as a drop does.
    final speed = velocity.distance;
    if (speed > 0.05) stretchAngle = velocity.direction;
    stretch.target = (speed * 6).clamp(0.0, 9.0);
    stretch.step(dt);
    grab.step(dt);
    if (!_holding || pull == 0) rubber.step(dt);
    return (!_holding || _fingerVelocity.distance < 0.001) &&
        x.resting(0.0008) &&
        y.resting(0.0008) &&
        stretch.resting(0.05) &&
        grab.resting(0.002) &&
        rubber.resting(0.05);
  }
}

/// The hues and guides, which never move: painted once, under the bead.
class _WheelDiscPainter extends CustomPainter {
  const _WheelDiscPainter({required this.ink});

  final Color ink;

  static final List<Color> _hues = <Color>[
    for (var degrees = 0; degrees <= 360; degrees += 30)
      HSVColor.fromAHSV(1, degrees % 360 * 1.0, 0.85, 1).toColor(),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 8;
    final disc = Rect.fromCircle(center: center, radius: radius);

    // Hues around the rim, red at the top and clockwise, fading to grey in
    // the middle, where the grade is neutral.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = SweepGradient(
          colors: _hues,
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(disc),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            const Color(0xFF7A7A7A),
            const Color(0xFF7A7A7A).withValues(alpha: 0.82),
            const Color(0xFF7A7A7A).withValues(alpha: 0.0),
          ],
          stops: const <double>[0, 0.45, 1],
        ).createShader(disc),
    );
    // A soft shade keeps the wheel quiet against the glass.
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFF000000).withValues(alpha: 0.28),
    );
    final hairline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ink.withValues(alpha: 0.10);
    canvas.drawCircle(center, radius * 0.5, hairline);
    canvas.drawLine(
      center - Offset(radius, 0),
      center + Offset(radius, 0),
      hairline,
    );
    canvas.drawLine(
      center - Offset(0, radius),
      center + Offset(0, radius),
      hairline,
    );
  }

  @override
  bool shouldRepaint(covariant _WheelDiscPainter oldDelegate) =>
      oldDelegate.ink != ink;
}

/// The rim and the bead.
class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.motion, required this.ink, required this.rim})
    : super(repaint: motion);

  final _WheelMotion motion;
  final Color ink;
  final Color rim;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 8;

    // Pulled past the rim, the rim gives like rubber toward the finger.
    final rubber = motion.rubber.value;
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = rim;
    if (rubber.abs() > 0.3) {
      final reach = Offset.fromDirection(motion.pullAngle, rubber * 0.5);
      canvas.drawOval(
        Rect.fromCenter(
          center: center + reach / 2,
          width: radius * 2 + reach.dx.abs(),
          height: radius * 2 + reach.dy.abs(),
        ),
        rimPaint,
      );
    } else {
      canvas.drawCircle(center, radius, rimPaint);
    }

    final puck = motion.puck;
    final distance = puck.distance;
    final atRim = distance > 1 ? puck / distance : puck;
    final position =
        center +
        atRim * radius +
        Offset.fromDirection(motion.pullAngle, rubber.clamp(0.0, 12.0) * 0.6);
    final grab = motion.grab.value.clamp(0.0, 1.2);
    final beadRadius = 7.5 * (1 + 0.24 * grab);
    final stretch = motion.stretch.value.clamp(-6.0, 12.0);

    // The line from the middle shows the push's hue and strength.
    if (distance > 0.02) {
      canvas.drawLine(
        center,
        position,
        Paint()
          ..strokeWidth = 1.2
          ..color = ink.withValues(alpha: 0.35),
      );
    }

    final hue = (wheelHue(atRim) * 180 / math.pi) % 360;
    final beadColor = distance < 0.02
        ? const Color(0xFF8C8C8C)
        : HSVColor.fromAHSV(
            1,
            hue,
            (0.25 + 0.6 * distance).clamp(0.0, 1.0),
            1,
          ).toColor();
    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.rotate(motion.stretchAngle);
    // Stretching thins it, as the recipe's squash and stretch does.
    final along = beadRadius * 2 + stretch;
    final across =
        beadRadius * 2 * (1 - (stretch / 10 * 0.045).clamp(0.0, 0.08));
    final bead = Rect.fromCenter(
      center: Offset(-stretch / 2, 0),
      width: along,
      height: across,
    );
    canvas.drawOval(
      bead.shift(const Offset(0, 1.5)),
      Paint()
        ..color = const Color(0xFF000000).withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawOval(bead, Paint()..color = beadColor);
    canvas.drawOval(
      bead,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 + 0.6 * grab
        ..color = ink.withValues(alpha: 0.75 + 0.25 * grab.clamp(0.0, 1.0)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WheelPainter oldDelegate) =>
      oldDelegate.motion != motion ||
      oldDelegate.ink != ink ||
      oldDelegate.rim != rim;
}
