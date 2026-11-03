import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../state/quick_settings.dart';
import '../state/system_level_hud.dart';
import 'liquid/liquid.dart';
import '../state/phone_desk.dart';

/// The phone's volume indicator: a liquid-filled capsule on the right edge,
/// centred in the top three quarters of the screen. It drops in from the
/// edge as a bead and stretches into a capsule; the level pours in on a
/// spring and its surface sloshes when it moves. A finger on it sets the
/// volume directly. Brightness changes show nothing on a phone.
class MobileVolumeHud extends ConsumerStatefulWidget {
  const MobileVolumeHud({super.key});

  @override
  ConsumerState<MobileVolumeHud> createState() => _MobileVolumeHudState();
}

class _MobileVolumeHudState extends ConsumerState<MobileVolumeHud>
    with SingleTickerProviderStateMixin {
  static const Duration _visibleFor = Duration(milliseconds: 1500);

  /// Movement under this, released quickly, is a tap that sets the level.
  static const double _tapSlop = 8;
  static const Duration _tapTime = Duration(milliseconds: 250);

  late final _VolumeMotion _motion = _VolumeMotion(this);
  Timer? _hideTimer;
  int _revision = 0;
  bool _muted = false;

  int? _pointer;
  double _dragStartLevel = 0;
  double _dragTravel = 0;
  Duration _pointerDownAt = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  bool _atLimit = false;

  @override
  void initState() {
    super.initState();
    _motion.addStatusListener(_motionStatusChanged);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  void _motionStatusChanged() {
    // Mount the capsule while it shows or leaves; drop it once gone.
    if (mounted) setState(() {});
  }

  void _present(SystemLevelHudState hud) {
    if (hud.kind != SystemLevelHudKind.audio || !hud.visible) return;
    if (hud.revision == _revision) return;
    _revision = hud.revision;
    _muted = hud.muted;
    _motion.reduced = MediaQuery.disableAnimationsOf(context);
    _motion.muted = hud.muted;
    // The finger owns the level while it is down.
    if (_pointer == null) {
      final direction = hud.level > hud.previousLevel
          ? 1
          : hud.level < hud.previousLevel
          ? -1
          : hud.level >= 1
          ? 1
          : hud.level <= 0
          ? -1
          : 0;
      _motion.present(
        level: hud.level,
        from: hud.previousLevel,
        direction: direction,
        limit: hud.limitReached,
      );
    } else {
      _motion.present(level: _motion.level, from: _motion.level);
    }
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_visibleFor, () {
      if (mounted && _pointer == null) _motion.dismiss();
    });
  }

  double _trackHeight(Rect rest) => rest.height * 0.92;

  void _pointerDown(PointerDownEvent event, Rect rest) {
    if (_pointer != null || !_motion.shown) return;
    _pointer = event.pointer;
    _hideTimer?.cancel();
    _dragStartLevel = _motion.levelTarget;
    _dragTravel = 0;
    _pointerDownAt = _clock.elapsed;
    _atLimit = false;
    ref.read(quickSettingsProvider.notifier).beginVolumeInteraction();
    _motion.grab(true);
  }

  void _pointerMove(PointerMoveEvent event, Rect rest) {
    if (event.pointer != _pointer) return;
    _dragTravel += event.delta.dy;
    final raw = _dragStartLevel - _dragTravel / _trackHeight(rest);
    final level = raw.clamp(0.0, 1.0).toDouble();
    _motion.follow(raw);
    final atLimit = raw <= 0 || raw >= 1;
    if (atLimit && !_atLimit) ref.read(hapticsServiceProvider).pulse();
    _atLimit = atLimit;
    ref.read(quickSettingsProvider.notifier).setDashboardVolume(level);
  }

  void _pointerUp(PointerEvent event, Rect rest, Offset localInRest) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    final tapped =
        event is PointerUpEvent &&
        _dragTravel.abs() < _tapSlop &&
        _clock.elapsed - _pointerDownAt < _tapTime;
    var level = _motion.levelTarget;
    if (tapped) {
      // A tap pours the level to where the finger was.
      final track = _trackHeight(rest);
      final bottom = rest.height - (rest.height - track) / 2;
      level = ((bottom - localInRest.dy) / track).clamp(0.0, 1.0).toDouble();
      _motion.pour(level);
    }
    _motion.release();
    ref.read(quickSettingsProvider.notifier).commitDashboardVolume(level);
    _armHide();
  }

  void _step(double delta) {
    final level = (_motion.levelTarget + delta).clamp(0.0, 1.0).toDouble();
    _motion.pour(level);
    ref.read(quickSettingsProvider.notifier).commitDashboardVolume(level);
    _armHide();
  }

  @override
  Widget build(BuildContext context) {
    // Beside a desk, the level shows on the screen used last.
    final part = ShellPart.of(context);
    ref.listen<SystemLevelHudState?>(systemLevelHudProvider, (_, hud) {
      if (hud == null) return;
      if (part == ShellPart.whole ||
          ref.read(activeShellPartProvider) == part) {
        _present(hud);
      }
    });
    if (!_motion.onScreen) return const SizedBox.shrink();

    final view = MediaQuery.sizeOf(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final rest = _VolumeMotion.restRect(view, padding);
    _motion.height = rest.height;
    final theme = ShellTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colors = _VolumeColors(
      smoke: dark ? const Color(0x73000000) : const Color(0x8CFFFFFF),
      rim: dark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
      fill: dark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E),
      ink: dark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E),
      inkOnFill: dark ? const Color(0xFF111114) : const Color(0xFFF5F5F7),
      shadow: const Color(0x59000000),
    );
    final percent = (_motion.levelTarget * 100).round();
    // The touch area is the capsule at rest, a little wider: it never moves
    // with the animation, so the input layout is published once.
    final touch = Rect.fromLTRB(
      rest.left - 14,
      rest.top - 10,
      view.width,
      rest.bottom + 10,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Shadow and capsule move together; only this layer repaints.
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _VolumeShadowPainter(_motion, rest, colors),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _motion,
          builder: (context, _) {
            final capsule = _motion.capsule(rest, view.width);
            return Positioned.fromRect(
              rect: capsule,
              child: IgnorePointer(
                child: ShellBackdropBlur(
                  separateChild: true,
                  borderRadius: BorderRadius.circular(capsule.shortestSide / 2),
                  child: CustomPaint(
                    size: capsule.size,
                    painter: _VolumeCapsulePainter(
                      motion: _motion,
                      colors: colors,
                      textDirection: Directionality.of(context),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        Positioned.fromRect(
          rect: touch,
          child: ShellInputRegion(
            debugLabel: 'Mobile volume',
            active: _motion.shown,
            child: Semantics(
              container: true,
              slider: true,
              label: context.l10n.outputVolumeSemantics,
              value: context.l10n.percentCompact(_muted ? 0 : percent),
              increasedValue: context.l10n.percentCompact(
                (percent + 5).clamp(0, 100),
              ),
              decreasedValue: context.l10n.percentCompact(
                (percent - 5).clamp(0, 100),
              ),
              onIncrease: () => _step(0.05),
              onDecrease: () => _step(-0.05),
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => _pointerDown(event, rest),
                onPointerMove: (event) => _pointerMove(event, rest),
                onPointerUp: (event) => _pointerUp(
                  event,
                  rest,
                  event.localPosition + touch.topLeft - rest.topLeft,
                ),
                onPointerCancel: (event) =>
                    _pointerUp(event, rest, Offset.zero),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

@immutable
class _VolumeColors {
  const _VolumeColors({
    required this.smoke,
    required this.rim,
    required this.fill,
    required this.ink,
    required this.inkOnFill,
    required this.shadow,
  });

  final Color smoke;
  final Color rim;
  final Color fill;
  final Color ink;
  final Color inkOnFill;
  final Color shadow;
}

/// Every moving part of the indicator, stepped together by one ticker and
/// painted without rebuilding widgets.
class _VolumeMotion extends ChangeNotifier {
  _VolumeMotion(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  static const double restWidth = 56;
  static const double rightMargin = 14;

  /// Centred in the top three quarters of the screen.
  static Rect restRect(Size view, EdgeInsets padding) {
    final height = (view.height * 0.36).clamp(200.0, 400.0).toDouble();
    final centre = view.height * 0.375;
    final right = view.width - padding.right - rightMargin;
    return Rect.fromLTRB(
      right - restWidth,
      centre - height / 2,
      right,
      centre + height / 2,
    );
  }

  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final List<VoidCallback> _statusListeners = [];

  /// 0 beyond the screen edge, 1 in place.
  final _slide = LiquidSpring(0, stiffness: 520, dampingRatio: 0.74);

  /// 0 a round bead, 1 the full capsule.
  final _grow = LiquidSpring(0, stiffness: 230, dampingRatio: 0.6);
  final _level = LiquidSpring(0, stiffness: 300, dampingRatio: 0.8);

  /// The liquid surface's bulge, in logical pixels, upward positive.
  final _surface = LiquidSpring(0, stiffness: 340, dampingRatio: 0.2);

  /// Squash and stretch along the capsule, in logical pixels: positive
  /// reaches up, negative down.
  final _stretch = LiquidSpring(0, stiffness: 520, dampingRatio: 0.42);
  final _grabbed = LiquidSpring(0, stiffness: 620, dampingRatio: 0.82);
  final _mute = LiquidSpring(0, stiffness: 420, dampingRatio: 0.9);

  /// Seconds of motion, for the ripple's phase.
  double _time = 0;
  bool _dragging = false;

  /// The capsule's length at rest, which turns level speed into pixels.
  double height = 300;
  bool _shown = false;
  bool reduced = false;

  bool get shown => _shown;

  /// Whether anything is on screen or on its way out.
  bool get onScreen => _shown || _slide.value > 0.001 || _ticker.isActive;

  double get level => _level.value.clamp(0.0, 1.0).toDouble();
  double get levelTarget => _level.target.clamp(0.0, 1.0).toDouble();
  set muted(bool value) => _mute.target = value ? 1 : 0;

  void addStatusListener(VoidCallback listener) =>
      _statusListeners.add(listener);

  void _notifyStatus() {
    for (final listener in List.of(_statusListeners)) {
      listener();
    }
  }

  void present({
    required double level,
    required double from,
    int direction = 0,
    bool limit = false,
  }) {
    final arriving = !_shown;
    _shown = true;
    if (arriving) {
      if (_slide.value < 0.05) {
        // A fresh entrance pours from the old level.
        _level.set(from);
        _grow.set(0);
        _surface.set(0);
        _stretch.set(0);
      }
      _slide
        ..tune(520, 0.74)
        ..target = 1;
      _grow
        ..tune(230, 0.6)
        ..target = 1;
    }
    _level.target = level;
    if (direction != 0) {
      // Each step tugs the capsule toward the change; a step against the
      // end of the range tugs harder and rings.
      _stretch.velocity +=
          direction * (limit ? LiquidTuning.limitKick : LiquidTuning.stepKick);
    }
    _start();
    if (arriving) _notifyStatus();
  }

  void dismiss() {
    if (!_shown) return;
    _shown = false;
    // The capsule draws back into a bead first, then the bead leaves.
    _grow
      ..tune(420, 1)
      ..target = 0;
    _slide
      ..tune(150, 1)
      ..target = 0;
    _start();
    _notifyStatus();
  }

  void grab(bool down) {
    _grabbed.target = down ? 1 : 0;
    _dragging = down;
    _start();
  }

  /// The finger sets the level itself; past either end the capsule is
  /// pulled like rubber instead.
  void follow(double raw) {
    final level = raw.clamp(0.0, 1.0).toDouble();
    final dt = math.max(_frameDt, 1 / 240);
    final velocity = (level - _level.value) / dt;
    // Smooth the finger's speed so the surface leans with it, not with
    // every jitter of the touch samples.
    _level.velocity = LiquidTuning.fingerVelocity(_level.velocity, velocity);
    _level.value = level;
    _level.target = level;
    final over = raw > 1 ? raw - 1 : (raw < 0 ? raw : 0.0);
    final pull = over * height;
    final rubber = LiquidTuning.rubber(pull);
    _stretch
      ..value = rubber
      ..target = rubber
      ..velocity = 0;
    _start();
  }

  void pour(double level) {
    _level.target = level;
    _start();
  }

  void release() {
    _dragging = false;
    _grabbed.target = 0;
    _stretch.target = 0;
    _start();
  }

  double _frameDt = 1 / 120;

  void _start() {
    if (reduced) {
      for (final spring in _springs) {
        spring.settle();
      }
      _surface.set(0);
      _stretch.set(0);
      notifyListeners();
      if (!_shown) _notifyStatus();
      return;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  List<LiquidSpring> get _springs => [
    _slide,
    _grow,
    _level,
    _surface,
    _stretch,
    _grabbed,
    _mute,
  ];

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
    // The surface lags the level's motion: rising, the middle leads; on
    // stopping it rings and settles.
    final speed = _level.velocity * height;
    _surface.target = LiquidTuning.surfaceTarget(speed);
    _surface.step(dt);
    _slide.step(dt);
    _grow.step(dt);
    _grabbed.step(dt);
    _mute.step(dt);
    if (_dragging) _level.velocity *= LiquidTuning.fingerDecay(dt);
    notifyListeners();

    final resting =
        !_dragging &&
        _slide.resting(0.001) &&
        _grow.resting(0.001) &&
        _level.resting(0.0005) &&
        _surface.resting(0.05) &&
        _stretch.resting(0.05) &&
        _grabbed.resting(0.001) &&
        _mute.resting(0.001);
    if (resting) {
      for (final spring in _springs) {
        spring.settle();
      }
      _ticker.stop();
      notifyListeners();
      if (!_shown) _notifyStatus();
    }
  }

  /// The capsule now, in screen coordinates.
  Rect capsule(Rect rest, double screenRight) {
    final grow = _grow.value;
    final bead = grow.clamp(0.0, 1.0).toDouble();
    final stretch = _stretch.value;
    // Width swells under the finger and thins as the capsule stretches;
    // the bead starts smaller than the capsule's width.
    final width =
        restWidth *
        (1 + 0.14 * _grabbed.value) *
        (1 - 0.03 * (stretch.abs() / 10).clamp(0.0, 1.5)) *
        (0.66 + 0.34 * bead);
    final full = rest.height + stretch.abs();
    final height = math.max(width, width + (full - width) * grow);
    final centreY = rest.center.dy - stretch / 2 * grow.clamp(0.0, 1.0);
    final rightAtRest = rest.right + (restWidth - width) / 2;
    final offscreen = screenRight + 12 - (rightAtRest - width);
    final right = rightAtRest + (1 - _slide.value) * offscreen;
    return Rect.fromLTRB(
      right - width,
      centreY - height / 2,
      right,
      centreY + height / 2,
    );
  }

  /// 0 while still a bead, 1 once the capsule has formed: the contents
  /// appear as it forms and leave first.
  double get contents {
    final t = ((_grow.value - 0.55) / 0.4).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  double get surface => _surface.value;
  double get grabbed => _grabbed.value;
  double get mute => _mute.value.clamp(0.0, 1.0).toDouble();
  double get time => _time;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _VolumeShadowPainter extends CustomPainter {
  _VolumeShadowPainter(this.motion, this.rest, this.colors)
    : super(repaint: motion);

  final _VolumeMotion motion;
  final Rect rest;
  final _VolumeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final capsule = motion.capsule(rest, size.width);
    if (capsule.left >= size.width) return;
    final shape = RRect.fromRectAndRadius(
      capsule,
      Radius.circular(capsule.shortestSide / 2),
    );
    canvas.drawShadow(
      Path()..addRRect(shape),
      colors.shadow,
      6 + 6 * motion.grabbed,
      false,
    );
  }

  @override
  bool shouldRepaint(_VolumeShadowPainter oldDelegate) =>
      oldDelegate.rest != rest || oldDelegate.colors != colors;
}

class _VolumeCapsulePainter extends CustomPainter {
  _VolumeCapsulePainter({
    required this.motion,
    required this.colors,
    required this.textDirection,
  });

  final _VolumeMotion motion;
  final _VolumeColors colors;
  final TextDirection textDirection;

  /// Laid-out numbers by value and colour; the fade and the two inks
  /// would otherwise lay text out on every frame.
  static final Map<(int, int), TextPainter> _labels = {};

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.shortestSide / 2);
    final shape = RRect.fromRectAndRadius(rect, radius);
    canvas.drawRRect(shape, Paint()..color = colors.smoke);

    final contents = motion.contents;
    final level = motion.level;
    final mute = motion.mute;

    // The liquid: its top is a curve that bulges with the surface spring
    // and tilts with a small ripple while it rings.
    final bulge = motion.surface;
    final fill = liquidFillPath(
      size,
      level: level,
      bulge: bulge,
      time: motion.time,
    );
    canvas.save();
    canvas.clipRRect(shape);
    final fillColor = Color.lerp(
      colors.fill,
      colors.fill.withValues(alpha: 0.38),
      mute,
    )!;
    if (level > 0 || bulge.abs() > 0.5) {
      canvas.drawPath(
        fill,
        Paint()
          ..color = fillColor.withValues(
            alpha: fillColor.a * (0.4 + 0.6 * motion._grow.value.clamp(0, 1)),
          ),
      );
    }
    canvas.restore();

    // The rim brightens under the finger.
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.rim.withValues(
          alpha: (colors.rim.a * (1 + motion.grabbed)).clamp(0, 1),
        ),
    );

    if (contents <= 0) return;

    // Glyph and number are drawn twice: in ink over the smoke, and in the
    // smoke's colour where the liquid covers them.
    final iconCentre = Offset(size.width / 2, size.height - size.width / 2);
    final percent = (level * 100).round();
    final labelCentre = Offset(size.width / 2, size.width / 2 + 2);
    for (final onFill in [false, true]) {
      canvas.save();
      if (onFill) {
        canvas.clipPath(fill);
      } else {
        canvas.clipPath(
          Path.combine(PathOperation.difference, Path()..addRect(rect), fill),
        );
      }
      final ink = (onFill ? colors.inkOnFill : colors.ink).withValues(
        alpha: contents,
      );
      _paintSpeaker(canvas, iconCentre, size.width * 0.42, ink, level, mute);
      final label = _label(percent, ink);
      label.paint(canvas, labelCentre - Offset(label.width, label.height) / 2);
      canvas.restore();
    }
  }

  TextPainter _label(int percent, Color ink) {
    final key = (percent, ink.toARGB32());
    final cached = _labels[key];
    if (cached != null) return cached;
    if (_labels.length >= 64) {
      for (final label in _labels.values) {
        label.dispose();
      }
      _labels.clear();
    }
    return _labels[key] = TextPainter(
      text: TextSpan(
        text: '$percent',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: ink,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: textDirection,
    )..layout();
  }

  /// A speaker whose three waves come in as the level climbs, each one
  /// swinging open from its middle; mute strikes it through.
  void _paintSpeaker(
    Canvas canvas,
    Offset centre,
    double size,
    Color ink,
    double level,
    double mute,
  ) {
    final unit = size / 24;
    canvas.save();
    canvas.translate(centre.dx - 12 * unit, centre.dy - 12 * unit);
    canvas.scale(unit);
    final body = Path()
      ..moveTo(3, 9.5)
      ..lineTo(7, 9.5)
      ..lineTo(12, 5)
      ..lineTo(12, 19)
      ..lineTo(7, 14.5)
      ..lineTo(3, 14.5)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..color = ink
        ..style = PaintingStyle.fill
        ..strokeJoin = StrokeJoin.round,
    );
    final wave = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round;
    const thresholds = [0.01, 0.34, 0.67];
    for (var index = 0; index < 3; index += 1) {
      final t = ((level - thresholds[index]) / 0.12 + 0.5).clamp(0.0, 1.0);
      final shown = t * t * (3 - 2 * t) * (1 - mute);
      if (shown <= 0.01) continue;
      final r = 3.6 + index * 3.4;
      final sweep = (0.5 + 0.5 * shown) * 1.7;
      wave.color = ink.withValues(alpha: ink.a * shown);
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(12.5, 12), radius: r),
        -sweep / 2,
        sweep,
        false,
        wave,
      );
    }
    if (mute > 0.01) {
      final strike = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = ink;
      const from = Offset(4, 4);
      const to = Offset(20, 20);
      canvas.drawLine(from, Offset.lerp(from, to, mute)!, strike);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VolumeCapsulePainter oldDelegate) => true;
}
