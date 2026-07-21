import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Single source of truth for the shell's motion language.
///
/// Every animated layer pulls its durations, curves and springs from here so
/// that the whole UI shares one coherent feel. Gesture-driven transitions
/// settle with [springTo]; scripted ones use the durations + [standard].
class Motion {
  const Motion._();

  // Scripted durations -------------------------------------------------------
  static const Duration overviewOpen = Duration(milliseconds: 380);
  static const Duration overviewClose = Duration(milliseconds: 280);
  static const Duration launch = Duration(milliseconds: 430);
  static const Duration launchReveal = Duration(milliseconds: 160);
  static const Duration focusZoom = Duration(milliseconds: 320);
  static const Duration shade = Duration(milliseconds: 230);
  static const Duration desktopPanelOpen = Duration(milliseconds: 400);
  static const Duration desktopPanelClose = Duration(milliseconds: 320);
  static const Duration homeFlyAway = Duration(milliseconds: 280);
  static const Duration tile = Duration(milliseconds: 160);
  static const Duration pill = Duration(milliseconds: 90);
  static const Duration cardSettle = Duration(milliseconds: 220);
  static const Duration wallpaperSelector = Duration(milliseconds: 360);
  static const Duration wallpaperReveal = Duration(milliseconds: 720);
  static const Duration desktopWindowRevealLeadIn = Duration(milliseconds: 64);
  static const Duration desktopWindowReveal = Duration(milliseconds: 320);
  static const Duration desktopWindowCloseExplosion =
      Duration(milliseconds: 400);
  static const Duration desktopWindowCloseImplode = Duration(milliseconds: 280);
  static const Duration desktopWindowCloseFade = Duration(milliseconds: 220);
  static const Duration windowSwitcherHoldDelay = Duration(milliseconds: 190);
  static const Duration windowSwitcherQuick = Duration(milliseconds: 280);
  static const Duration windowSwitcherExpand = Duration(milliseconds: 320);
  static const Duration windowSwitcherCycle = Duration(milliseconds: 240);
  static const Duration windowSwitcherCollapse = Duration(milliseconds: 280);
  static const Duration systemLevelHud = Duration(milliseconds: 220);
  static const Duration systemLevelHudValue = Duration(milliseconds: 260);
  static const Duration notificationBanner = Duration(milliseconds: 260);
  static const Duration unlock = Duration(milliseconds: 1320);

  // Curves -------------------------------------------------------------------
  static const Curve standard = Curves.easeOutCubic;
  static const Curve desktopWindowRevealCurve = Curves.easeOut;
  static const Curve emphasized = Curves.easeOutQuart;
  static const Curve md3Emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve md3EmphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve md3EmphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Large-distance SUPER+A motion. Unlike the panel-oriented MD3 curves,
  /// both curves have zero endpoint velocity so a live window neither jumps
  /// away from its desktop position nor snaps into its final rectangle.
  static const Curve overviewEnterCurve = Cubic(0.33, 0.0, 0.15, 1.0);
  static const Curve overviewExitCurve = Cubic(0.55, 0.0, 0.45, 1.0);

  /// Used only when SUPER+A reverses before the preceding transition ends.
  /// A modest non-zero initial slope avoids a perceptible stop at the reversal
  /// point, while the zero terminal slope still settles cleanly.
  static const Curve overviewReversalCurve = Cubic(0.4, 0.2, 0.2, 1.0);

  // Springs (tuned for normalised [0,1] controllers) -------------------------
  // Damping is kept at / just below critical so motion is lively but does not
  // visibly overshoot the layout. mass=1, critical damping ~= 2*sqrt(stiffness).

  /// General settle for layer-sized transitions (overview, shade).
  static const SpringDescription gentle = SpringDescription(
    mass: 1.0,
    stiffness: 360.0,
    damping: 36.0,
  );

  /// Quicker settle for smaller, more responsive elements (cards, switch).
  static const SpringDescription snappy = SpringDescription(
    mass: 1.0,
    stiffness: 520.0,
    damping: 44.0,
  );

  /// Slightly springy settle that allows a touch of overshoot, for the
  /// rubber-band return of a half-dismissed card.
  static const SpringDescription bouncy = SpringDescription(
    mass: 1.0,
    stiffness: 460.0,
    damping: 34.0,
  );
}

/// Clamps [value] to the unit interval `[0, 1]`.
double unit(double value) => value.clamp(0.0, 1.0).toDouble();

/// Re-maps [value] from the sub-range `[begin, end]` onto `[0, 1]`.
double interval(double value, double begin, double end) {
  if (value <= begin) return 0.0;
  if (value >= end) return 1.0;
  return ((value - begin) / (end - begin)).clamp(0.0, 1.0).toDouble();
}

/// Drives [controller] to [target] with a spring seeded by [velocity].
///
/// [velocity] is expressed in controller-value units per second, so a caller
/// translating a pixel fling should divide the pixel velocity by the gesture's
/// travel distance before passing it here. Use an unbounded controller when the
/// chosen [spring] is allowed to overshoot.
TickerFuture springTo(
  AnimationController controller,
  double target, {
  double velocity = 0.0,
  SpringDescription spring = Motion.gentle,
  String telemetryLabel = 'spring',
}) {
  final future = controller.animateWith(
    SpringSimulation(spring, controller.value, target, velocity),
  );
  return MotionTelemetry.observe(
    controller,
    future,
    telemetryLabel,
    target: target,
  );
}

/// Opt-in animation and scheduler telemetry for the embedded shell.
///
/// Enable with `DENIA_DART_FRAME_TRACE=1`. It remains completely dormant in
/// normal operation. During a traced animation it reports controller ticks and
/// the number of transient callbacks queued for the following frame. That lets
/// the host-side vsync trace distinguish a stopped ticker from a delayed frame.
class MotionTelemetry {
  MotionTelemetry._();

  static bool _enabled = false;
  static final Stopwatch _clock = Stopwatch()..start();
  static var _installed = false;
  static var _activeAnimations = 0;
  static var _frameCount = 0;
  static Duration? _lastFrameTimestamp;

  static void install({required bool enabled}) {
    if (_installed) {
      return;
    }
    _enabled = enabled;
    if (!_enabled) {
      return;
    }
    _installed = true;
    event('telemetry_start');

    SchedulerBinding.instance.addPersistentFrameCallback((timestamp) {
      _frameCount += 1;
      final previous = _lastFrameTimestamp;
      _lastFrameTimestamp = timestamp;
      final gapUs =
          previous == null ? 0 : (timestamp - previous).inMicroseconds;
      if (_activeAnimations > 0 || gapUs > 20000 || _frameCount <= 5) {
        event(
          'scheduler_frame',
          fields: <String, Object>{
            'frame': _frameCount,
            'gap_us': gapUs,
            'active': _activeAnimations,
            'transient': SchedulerBinding.instance.transientCallbackCount,
          },
        );
      }
    });

    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final timing in timings) {
        final totalUs = timing.totalSpan.inMicroseconds;
        if (_activeAnimations > 0 || totalUs > 12000) {
          event(
            'frame_timing',
            fields: <String, Object>{
              'build_us': timing.buildDuration.inMicroseconds,
              'raster_us': timing.rasterDuration.inMicroseconds,
              'total_us': totalUs,
            },
          );
        }
      }
    });
  }

  static TickerFuture observe(
    AnimationController controller,
    TickerFuture future,
    String label, {
    double? target,
  }) {
    if (!_enabled) {
      return future;
    }

    final startedUs = _clock.elapsedMicroseconds;
    var lastTickUs = startedUs;
    var ticks = 0;
    var finished = false;

    void listener() {
      final nowUs = _clock.elapsedMicroseconds;
      final gapUs = nowUs - lastTickUs;
      lastTickUs = nowUs;
      ticks += 1;
      if (ticks <= 3 || gapUs > 12000 || ticks % 60 == 0) {
        event(
          'animation_tick',
          fields: <String, Object>{
            'label': label,
            'tick': ticks,
            'gap_us': gapUs,
            'value': controller.value.toStringAsFixed(6),
            'animating': controller.isAnimating ? 1 : 0,
          },
        );
      }
    }

    controller.addListener(listener);
    _activeAnimations += 1;
    event(
      'animation_start',
      fields: <String, Object>{
        'label': label,
        'value': controller.value.toStringAsFixed(6),
        if (target != null) 'target': target.toStringAsFixed(6),
        'active': _activeAnimations,
      },
    );

    future.whenCompleteOrCancel(() {
      if (finished) {
        return;
      }
      finished = true;
      controller.removeListener(listener);
      _activeAnimations -= 1;
      event(
        'animation_end',
        fields: <String, Object>{
          'label': label,
          'ticks': ticks,
          'elapsed_us': _clock.elapsedMicroseconds - startedUs,
          'value': controller.value.toStringAsFixed(6),
          'active': _activeAnimations,
        },
      );
    });
    return future;
  }

  static void event(
    String name, {
    Map<String, Object> fields = const <String, Object>{},
  }) {
    if (!_enabled) {
      return;
    }
    final buffer = StringBuffer(
      'Denial dart_frame ts_us=${_clock.elapsedMicroseconds} event=$name',
    );
    for (final entry in fields.entries) {
      buffer
        ..write(' ')
        ..write(entry.key)
        ..write('=')
        ..write(entry.value);
    }
    debugPrintSynchronously(buffer.toString());
  }
}
