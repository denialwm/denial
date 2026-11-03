import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import '../liquid/liquid.dart';
import '../liquid/water_reveal.dart' show LiquidRevealScope;

/// The shade's vertical brightness and volume slider, filled with liquid
/// as the volume indicator is (`docs/LIQUID_MOTION.md`).
///
/// A finger moves the level from where it was, directly; a tap pours it to
/// the tapped height. Past either end the bar stretches like rubber. A
/// change from elsewhere pours in and tugs the bar toward it, and when the
/// shade reveals the bar the level pours up from empty.
class LiquidRangeBar extends StatefulWidget {
  const LiquidRangeBar({
    super.key,
    required this.icon,
    required this.value,
    required this.trackColor,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeStart,
    this.iconScale = 1,
  });

  final IconData icon;
  final double value;
  final Color trackColor;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback? onChangeStart;
  final double iconScale;

  @override
  State<LiquidRangeBar> createState() => _LiquidRangeBarState();
}

class _LiquidRangeBarState extends State<LiquidRangeBar>
    with SingleTickerProviderStateMixin {
  static const double _step = 0.05;

  /// A drag starts after this much travel; the travel before it counts.
  static const double _touchSlop = 4;

  /// Rubber reach inside the grid, where the gutter is narrow.
  static const double _reach = 12;

  late final _LiquidBarMotion _motion = _LiquidBarMotion(this, widget.value);
  ValueListenable<double>? _reveal;
  double _revealValue = 0;
  double _dragStart = 0;
  double _dragTravel = 0;
  bool _dragging = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.reduced = MediaQuery.disableAnimationsOf(context);
    final reveal = LiquidRevealScope.maybeOf(context);
    if (reveal != _reveal) {
      _reveal?.removeListener(_revealChanged);
      _reveal = reveal?..addListener(_revealChanged);
      _revealValue = reveal?.value ?? 1;
    }
  }

  @override
  void didUpdateWidget(covariant LiquidRangeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // While the finger holds the bar, the value coming back is its own.
    if (!_dragging) _motion.pour(widget.value, tug: true);
  }

  @override
  void dispose() {
    _reveal?.removeListener(_revealChanged);
    _motion.dispose();
    super.dispose();
  }

  void _revealChanged() {
    final value = _reveal!.value;
    // Once the bead has stretched into the bar, the level pours up.
    if (_revealValue < 0.6 && value >= 0.6 && !_dragging) {
      _motion.pourFromEmpty(widget.value);
    }
    _revealValue = value;
  }

  void _dragStarted(DragStartDetails details) {
    _dragging = true;
    _dragStart = _motion.target;
    _dragTravel = 0;
    widget.onChangeStart?.call();
    _motion.grab(true);
  }

  void _dragUpdated(DragUpdateDetails details, double height) {
    _dragTravel += details.delta.dy;
    final raw = _dragStart - _dragTravel / math.max(1.0, height);
    _motion.follow(raw, height, _reach);
    widget.onChanged(raw.clamp(0.0, 1.0).toDouble());
  }

  void _dragEnded() {
    if (!_dragging) return;
    _dragging = false;
    _motion.release();
    widget.onChangeEnd(_motion.target);
  }

  void _tapped(TapUpDetails details, double height) {
    if (height <= 0) return;
    final value = (1 - details.localPosition.dy / height)
        .clamp(0.0, 1.0)
        .toDouble();
    widget.onChangeStart?.call();
    _motion.pour(value, tug: true);
    widget.onChanged(value);
    widget.onChangeEnd(value);
  }

  void _adjust(double delta) {
    final next = (_motion.target + delta).clamp(0.0, 1.0).toDouble();
    if (next == _motion.target) return;
    widget.onChangeStart?.call();
    _motion.pour(next, tug: true);
    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _adjust(-event.scrollDelta.dy.sign * _step),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    final palette = _LiquidBarColors(
      track: theme.cardColor(widget.trackColor),
      rim: colors.hairlineSoft,
      fill: theme.accent,
      ink: colors.panelText,
      inkOnFill: theme.accentPalette.onPrimary,
    );
    final percent = (_motion.target * 100).round();
    final media = MediaQuery.of(context);
    return Semantics(
      slider: true,
      value: '$percent%',
      increasedValue: '${(percent + 5).clamp(0, 100)}%',
      decreasedValue: '${(percent - 5).clamp(0, 100)}%',
      onIncrease: () => _adjust(_step),
      onDecrease: () => _adjust(-_step),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final radius = theme.scaledRadius(20);
          return Listener(
            onPointerSignal: _handlePointerSignal,
            // A short slop: the bar answers almost at once, and the travel
            // before the drag starts still counts.
            child: MediaQuery(
              data: media.copyWith(
                gestureSettings: const DeviceGestureSettings(
                  touchSlop: _touchSlop,
                ),
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onTapUp: (details) => _tapped(details, height),
                onVerticalDragStart: _dragStarted,
                onVerticalDragUpdate: (details) =>
                    _dragUpdated(details, height),
                onVerticalDragEnd: (_) => _dragEnded(),
                onVerticalDragCancel: _dragEnded,
                child: Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    AnimatedBuilder(
                      animation: _motion,
                      builder: (context, _) {
                        final shape = _motion.shape(constraints.biggest);
                        return Positioned.fromRect(
                          rect: shape,
                          child: ShellBackdropBlur(
                            blur:
                                _motion.level < 1 &&
                                theme.effectivePanelOpacity < 1,
                            borderRadius: BorderRadius.circular(
                              math.min(radius, shape.shortestSide / 2),
                            ),
                            child: CustomPaint(
                              size: shape.size,
                              painter: _LiquidBarPainter(
                                motion: _motion,
                                colors: palette,
                                radius: radius,
                                icon: widget.icon,
                                iconSize: 24 * widget.iconScale,
                                textDirection: Directionality.of(context),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

@immutable
class _LiquidBarColors {
  const _LiquidBarColors({
    required this.track,
    required this.rim,
    required this.fill,
    required this.ink,
    required this.inkOnFill,
  });

  final Color track;
  final Color rim;
  final Color fill;
  final Color ink;
  final Color inkOnFill;

  @override
  bool operator ==(Object other) =>
      other is _LiquidBarColors &&
      other.track == track &&
      other.rim == rim &&
      other.fill == fill &&
      other.ink == ink &&
      other.inkOnFill == inkOnFill;

  @override
  int get hashCode => Object.hash(track, rim, fill, ink, inkOnFill);
}

class _LiquidBarMotion extends ChangeNotifier {
  _LiquidBarMotion(TickerProvider vsync, double value)
    : _level = LiquidTuning.level(value.clamp(0.0, 1.0).toDouble()) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final LiquidSpring _level;
  final LiquidSpring _surface = LiquidTuning.surface();
  final LiquidSpring _stretch = LiquidTuning.stretch();
  final LiquidSpring _grabbed = LiquidTuning.grab();
  double _time = 0;
  double _frameDt = 1 / 120;
  double _height = 140;
  bool _dragging = false;
  bool reduced = false;

  double get level => _level.value.clamp(0.0, 1.0).toDouble();
  double get target => _level.target.clamp(0.0, 1.0).toDouble();
  double get surface => _surface.value;
  double get grabbed => _grabbed.value;
  double get time => _time;

  void pour(double value, {bool tug = false}) {
    final next = value.clamp(0.0, 1.0).toDouble();
    final change = next - _level.target;
    if (change.abs() < 0.001) return;
    _level.target = next;
    if (tug) _stretch.velocity += change.sign * LiquidTuning.stepKick;
    _start();
  }

  void pourFromEmpty(double value) {
    _level.set(0);
    _level.target = value.clamp(0.0, 1.0).toDouble();
    _stretch.velocity += LiquidTuning.stepKick;
    _start();
  }

  void grab(bool down) {
    _dragging = down;
    _grabbed.target = down ? 1 : 0;
    _start();
  }

  void follow(double raw, double height, double reach) {
    _height = height;
    final value = raw.clamp(0.0, 1.0).toDouble();
    final dt = math.max(_frameDt, 1 / 240);
    _level.velocity = LiquidTuning.fingerVelocity(
      _level.velocity,
      (value - _level.value) / dt,
    );
    _level.value = value;
    _level.target = value;
    final over = raw > 1 ? raw - 1 : (raw < 0 ? raw : 0.0);
    final rubber = LiquidTuning.rubber(over * height, reach: reach);
    _stretch
      ..value = rubber
      ..target = rubber
      ..velocity = 0;
    _start();
  }

  void release() {
    _dragging = false;
    _grabbed.target = 0;
    _stretch.target = 0;
    _start();
  }

  List<LiquidSpring> get _springs => [_level, _surface, _stretch, _grabbed];

  void _start() {
    if (reduced) {
      for (final spring in _springs) {
        spring.settle();
      }
      _surface.set(0);
      if (!_dragging) _stretch.set(0);
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
    _frameDt = dt;
    _time += dt;
    if (!_dragging) {
      _level.step(dt);
      _stretch.step(dt);
    }
    _surface.target = LiquidTuning.surfaceTarget(_level.velocity * _height);
    _surface.step(dt);
    _grabbed.step(dt);
    if (_dragging) _level.velocity *= LiquidTuning.fingerDecay(dt);
    notifyListeners();
    final resting =
        !_dragging &&
        _level.resting(0.0005) &&
        _surface.resting(0.05) &&
        _stretch.resting(0.05) &&
        _grabbed.resting(0.001);
    if (resting) {
      for (final spring in _springs) {
        spring.settle();
      }
      _ticker.stop();
      notifyListeners();
    }
  }

  /// The bar now, in its own box: it swells a little under the finger and
  /// stretches past the end it is pulled at, thinning as it does.
  Rect shape(Size size) {
    _height = size.height;
    final stretch = _stretch.value;
    final swell = 3 * _grabbed.value;
    final thin = size.width * 0.03 * (stretch.abs() / 10).clamp(0.0, 1.5);
    return Rect.fromLTRB(
      -swell + thin / 2,
      -swell - math.max(0.0, stretch),
      size.width + swell - thin / 2,
      size.height + swell + math.max(0.0, -stretch),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _LiquidBarPainter extends CustomPainter {
  _LiquidBarPainter({
    required this.motion,
    required this.colors,
    required this.radius,
    required this.icon,
    required this.iconSize,
    required this.textDirection,
  });

  final _LiquidBarMotion motion;
  final _LiquidBarColors colors;
  final double radius;
  final IconData icon;
  final double iconSize;
  final TextDirection textDirection;

  /// Laid-out glyphs by text, size and colour.
  static final Map<(String, double, int), TextPainter> _glyphs = {};

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.min(radius, size.shortestSide / 2)),
    );
    canvas.drawRRect(shape, Paint()..color = colors.track);

    final level = motion.level;
    final fill = liquidFillPath(
      size,
      level: level,
      bulge: motion.surface,
      time: motion.time,
    );
    canvas.save();
    canvas.clipRRect(shape);
    if (level > 0 || motion.surface.abs() > 0.5) {
      canvas.drawPath(fill, Paint()..color = colors.fill);
    }
    canvas.restore();
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.rim,
    );

    // The glyph and, under the finger, the number: in ink over the track
    // and in the fill's ink where the liquid covers them.
    final grabbed = motion.grabbed.clamp(0.0, 1.0);
    final glyph = String.fromCharCode(icon.codePoint);
    final iconCentre = Offset(size.width / 2, size.height - 10 - 12);
    final number = '${(level * 100).round()}';
    final numberCentre = Offset(size.width / 2, 22);
    for (final onFill in [false, true]) {
      canvas.save();
      if (onFill) {
        canvas.clipPath(fill);
      } else {
        canvas.clipPath(
          Path.combine(PathOperation.difference, Path()..addRect(rect), fill),
        );
      }
      final ink = onFill ? colors.inkOnFill : colors.ink;
      final iconPainter = _text(glyph, iconSize, ink, icon: icon);
      iconPainter.paint(
        canvas,
        iconCentre - Offset(iconPainter.width, iconPainter.height) / 2,
      );
      if (grabbed > 0.02) {
        final label = _text(number, 14, ink.withValues(alpha: ink.a * grabbed));
        label.paint(
          canvas,
          numberCentre - Offset(label.width, label.height) / 2,
        );
      }
      canvas.restore();
    }
  }

  TextPainter _text(String text, double size, Color color, {IconData? icon}) {
    final key = (text, size, color.toARGB32());
    final cached = _glyphs[key];
    if (cached != null) return cached;
    if (_glyphs.length >= 96) {
      for (final painter in _glyphs.values) {
        painter.dispose();
      }
      _glyphs.clear();
    }
    return _glyphs[key] = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontFamily: icon?.fontFamily,
          package: icon?.fontPackage,
          fontWeight: icon == null ? FontWeight.w600 : null,
          fontFeatures: icon == null
              ? const [FontFeature.tabularFigures()]
              : null,
          height: icon == null ? null : 1,
        ),
      ),
      textDirection: textDirection,
    )..layout();
  }

  @override
  bool shouldRepaint(_LiquidBarPainter oldDelegate) => true;
}
