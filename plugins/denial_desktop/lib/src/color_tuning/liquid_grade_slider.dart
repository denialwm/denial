import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../widgets/liquid/liquid.dart';

/// A bipolar slider whose fill pours out of the middle, after
/// `docs/LIQUID_MOTION.md`. The finger drags relative to where it went down,
/// for fine control; a double tap pours it back to zero.
class LiquidGradeSlider extends StatefulWidget {
  const LiquidGradeSlider({
    super.key,
    required this.value,
    required this.range,
    required this.revision,
    required this.onChanged,
    required this.track,
    required this.fill,
    required this.ink,
    this.height = 22,
    this.semanticLabel,
  });

  /// In -range..range.
  final double value;
  final double range;

  /// Advances when [value] changed from outside; the fill then pours to it.
  final int revision;

  /// Every move with `save: false`, and the release with `save: true`.
  final void Function(double value, {required bool save}) onChanged;

  /// The track's colors from its left end to its right end.
  final List<Color> track;
  final Color fill;
  final Color ink;
  final double height;
  final String? semanticLabel;

  @override
  State<LiquidGradeSlider> createState() => _LiquidGradeSliderState();
}

class _LiquidGradeSliderState extends State<LiquidGradeSlider>
    with SingleTickerProviderStateMixin {
  late final _LiquidSliderMotion _motion = _LiquidSliderMotion(
    this,
    widget.value / widget.range,
  );
  int? _pointer;
  double _downValue = 0;
  double _downX = 0;
  double _value = 0;
  bool _moved = false;
  double _width = 1;
  Timer? _scrollSave;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(covariant LiquidGradeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision && _pointer == null) {
      _value = widget.value;
      _motion.pourTo(_value / widget.range, reduceMotion: _reduceMotion);
    }
  }

  @override
  void dispose() {
    _scrollSave?.cancel();
    _motion.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downX = event.localPosition.dx;
    _downValue = _value;
    _moved = false;
    _motion.hold(reduceMotion: _reduceMotion);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    // Half the track spans the whole range, slowed for fine grading.
    final travel = (event.localPosition.dx - _downX) / (_width / 2) * 0.75;
    final wanted = _downValue / widget.range + travel;
    final clamped = wanted.clamp(-1.0, 1.0);
    final pull = (wanted - clamped) * _width / 2;
    if (pull != 0 && _motion.pull == 0) {
      HapticFeedback.selectionClick();
    }
    _motion.follow(clamped, pull, event.timeStamp, _reduceMotion);
    final next = _snap(clamped * widget.range);
    if (next != _value) {
      _value = next;
      _moved = true;
      widget.onChanged(_value, save: false);
    }
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _motion.release(reduceMotion: _reduceMotion);
    if (_moved) widget.onChanged(_value, save: true);
  }

  void _scroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final step = event.scrollDelta.dy.sign * -0.02;
    if (step == 0) return;
    final wanted = _value / widget.range + step;
    final next = _snap(wanted.clamp(-1.0, 1.0) * widget.range);
    _motion.step(
      next / widget.range,
      atEnd: wanted.abs() > 1,
      reduceMotion: _reduceMotion,
    );
    if (next != _value) {
      _value = next;
      widget.onChanged(_value, save: false);
      // Scrolling saves once it pauses, not on every notch.
      _scrollSave?.cancel();
      _scrollSave = Timer(const Duration(milliseconds: 600), () {
        if (mounted) widget.onChanged(_value, save: true);
      });
    }
  }

  void _reset() {
    if (_value == 0) return;
    _value = 0;
    _motion.pourTo(0, reduceMotion: _reduceMotion);
    widget.onChanged(0, save: true);
  }

  /// Keeps values to what the readout shows, and lets zero catch.
  double _snap(double value) {
    final rounded = (value * 100).round() / 100;
    return rounded.abs() < widget.range * 0.015 ? 0 : rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: _value.toStringAsFixed(2),
      child: GestureDetector(
        onDoubleTap: _reset,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          onPointerSignal: _scroll,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _width = math.max(1, constraints.maxWidth);
              return CustomPaint(
                size: Size(constraints.maxWidth, widget.height),
                painter: _LiquidSliderPainter(
                  motion: _motion,
                  track: widget.track,
                  fill: widget.fill,
                  ink: widget.ink,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LiquidSliderMotion extends LiquidMotion {
  _LiquidSliderMotion(super.vsync, double level)
    : level = LiquidTuning.level(level);

  /// -1..1 along the track.
  final LiquidSpring level;

  /// The fill's leading edge leans with its speed, in pixels.
  final LiquidSpring surface = LiquidTuning.surface();

  /// Rubber past either end, in pixels.
  final LiquidSpring stretch = LiquidTuning.stretch();
  final LiquidSpring grab = LiquidTuning.grab();
  double time = 0;
  double pull = 0;
  double _fingerSpeed = 0;
  Duration? _lastSample;
  double _lastLevel = 0;
  bool _holding = false;

  @override
  List<LiquidSpring> get springs => [level, surface, stretch, grab];

  void hold({required bool reduceMotion}) {
    _holding = true;
    grab.target = 1;
    _fingerSpeed = 0;
    _lastSample = null;
    _lastLevel = level.value;
    kick(reduceMotion: reduceMotion);
  }

  /// The finger sets the level directly; springs only shape the liquid.
  void follow(double next, double pullPixels, Duration at, bool reduceMotion) {
    final previous = _lastSample;
    if (previous != null) {
      final dt = (at - previous).inMicroseconds / 1e6;
      if (dt > 0) {
        _fingerSpeed = LiquidTuning.fingerVelocity(
          _fingerSpeed,
          (next - _lastLevel) / dt,
        );
      }
    }
    _lastSample = at;
    _lastLevel = next;
    level.set(next);
    pull = pullPixels;
    stretch.set(LiquidTuning.rubber(pullPixels, reach: 10));
    kick(reduceMotion: reduceMotion);
  }

  void release({required bool reduceMotion}) {
    _holding = false;
    grab.target = 0;
    pull = 0;
    stretch.target = 0;
    kick(reduceMotion: reduceMotion);
  }

  void pourTo(double next, {required bool reduceMotion}) {
    level.target = next;
    kick(reduceMotion: reduceMotion);
  }

  /// One scroll notch: the fill pours and the body tugs toward the change,
  /// harder against an end.
  void step(double next, {required bool atEnd, required bool reduceMotion}) {
    final direction = (next - level.target).sign;
    level.target = next;
    stretch.velocity += atEnd
        ? LiquidTuning.limitKick * 0.4 * (next.sign == 0 ? 1 : next.sign)
        : LiquidTuning.stepKick * 0.2 * direction;
    kick(reduceMotion: reduceMotion);
  }

  @override
  bool advance(double dt) {
    time += dt;
    final speed = _holding ? _fingerSpeed : level.velocity;
    if (_holding) _fingerSpeed *= LiquidTuning.fingerDecay(dt);
    // One unit of level is about a hundred pixels of track.
    surface.target = LiquidTuning.surfaceTarget(speed * 100) * 0.6;
    level.step(dt);
    surface.step(dt);
    if (!_holding || pull == 0) stretch.step(dt);
    grab.step(dt);
    // A finger resting on the control lets the ticker stop too.
    return (!_holding || _fingerSpeed.abs() < 0.001) &&
        level.resting(0.001) &&
        surface.resting(0.05) &&
        stretch.resting(0.05) &&
        grab.resting(0.002);
  }
}

class _LiquidSliderPainter extends CustomPainter {
  _LiquidSliderPainter({
    required this.motion,
    required this.track,
    required this.fill,
    required this.ink,
  }) : super(repaint: motion);

  final _LiquidSliderMotion motion;
  final List<Color> track;
  final Color fill;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final grab = motion.grab.value.clamp(0.0, 1.2);
    final stretch = motion.stretch.value;
    final thickness = (size.height * 0.36) * (1 + 0.14 * grab);
    final centerY = size.height / 2;
    // Rubber past an end lengthens the track toward the pull.
    final left = math.min(0.0, stretch) + thickness / 2;
    final right = size.width + math.max(0.0, stretch) - thickness / 2;
    final middle = size.width / 2;
    final trackRect = Rect.fromLTRB(
      left - thickness / 2,
      centerY - thickness / 2,
      right + thickness / 2,
      centerY + thickness / 2,
    );
    final capsule = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(thickness / 2),
    );
    canvas.drawRRect(
      capsule,
      Paint()..shader = LinearGradient(colors: track).createShader(trackRect),
    );

    final level = motion.level.value.clamp(-1.08, 1.08);
    final end = middle + level * (right - middle);
    if ((end - middle).abs() > 0.5) {
      canvas.save();
      canvas.clipRRect(capsule);
      final top = centerY - thickness / 2;
      final bottom = centerY + thickness / 2;
      final direction = level.sign;
      // The leading edge bulges with the pour and rings when it stops.
      final bulge = motion.surface.value * direction;
      final ripple = bulge.abs() * 0.4 * math.sin(motion.time * 26);
      final path = Path()
        ..moveTo(middle, top)
        ..lineTo(end + ripple, top)
        ..cubicTo(
          end + bulge,
          top + thickness * 0.3,
          end + bulge,
          bottom - thickness * 0.3,
          end - ripple,
          bottom,
        )
        ..lineTo(middle, bottom)
        ..close();
      canvas.drawPath(path, Paint()..color = fill);
      canvas.restore();
    }

    // The middle notch, and the meniscus bead the finger holds.
    canvas.drawCircle(
      Offset(middle, centerY),
      1.5,
      Paint()..color = ink.withValues(alpha: 0.45),
    );
    final beadRadius = thickness * (0.62 + 0.18 * grab);
    canvas.drawCircle(
      Offset(end, centerY),
      beadRadius,
      Paint()..color = Color.lerp(fill, ink, 0.35 + 0.35 * grab)!,
    );
    canvas.drawCircle(
      Offset(end, centerY),
      beadRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ink.withValues(alpha: 0.5 + 0.4 * grab),
    );
  }

  @override
  bool shouldRepaint(covariant _LiquidSliderPainter oldDelegate) =>
      oldDelegate.motion != motion ||
      !listEquals(oldDelegate.track, track) ||
      oldDelegate.fill != fill ||
      oldDelegate.ink != ink;
}
