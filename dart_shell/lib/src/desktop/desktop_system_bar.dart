import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../models/shell_clock_info.dart';
import '../state/system_status.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_accent.dart';

/// The desktop system bar. Its strip is reserved from the window work area,
/// so windows maximize beside it while true fullscreen covers it.
///
/// The strip itself paints nothing: modules float as borderless pill cards
/// over the bare wallpaper, and every card follows the wallpaper's extracted
/// accent. Cards cluster at the trailing edge of the strip and spring in one
/// after another when the bar mounts.
class DesktopSystemBar extends ConsumerWidget {
  const DesktopSystemBar({required this.side, super.key});

  static const double _edgePadding = 8.0;
  static const double _cardMargin = 5.0;
  static const double _cardGap = 8.0;

  final SystemBarSide side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(wallpaperAccentProvider);
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final locale = ref.watch(clockLocaleProvider);
    final cpu = ref.watch(cpuUsageProvider);
    final gpus = ref.watch(gpuUsageProvider);
    final horizontal = side.isHorizontal;
    final cpuVisible = cpu.current != null;
    return Padding(
      padding: horizontal
          ? const EdgeInsets.symmetric(
              horizontal: _edgePadding,
              vertical: _cardMargin,
            )
          : const EdgeInsets.symmetric(
              horizontal: _cardMargin,
              vertical: _edgePadding,
            ),
      child: Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (int i = 0; i < gpus.length; i += 1)
            _SystemBarEntrance(
              key: ValueKey('system-bar-gpu-${gpus[i].id}'),
              index: (cpuVisible ? 1 : 0) + (gpus.length - i),
              horizontal: horizontal,
              // The gap rides inside the entrance so the neighbouring pill
              // slides over smoothly when this one appears.
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _SystemBarCard(
                  accent: accent,
                  child: _MeterModule(
                    accent: accent,
                    label: gpus[i].label,
                    series: gpus[i].series,
                  ),
                ),
              ),
            ),
          if (cpuVisible)
            _SystemBarEntrance(
              key: const ValueKey('system-bar-cpu'),
              index: 1,
              horizontal: horizontal,
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _SystemBarCard(
                  accent: accent,
                  child: _MeterModule(
                    accent: accent,
                    label: 'CPU',
                    series: cpu,
                  ),
                ),
              ),
            ),
          _SystemBarEntrance(
            key: const ValueKey('system-bar-clock'),
            index: 0,
            horizontal: horizontal,
            child: _SystemBarCard(
              accent: accent,
              child: _ClockModule(accent: accent, now: now, locale: locale),
            ),
          ),
        ],
      ),
    );
  }
}

/// Date caption plus the ticking clock. The caption re-tints with the
/// wallpaper accent; minute changes crossfade with a small upward slide.
class _ClockModule extends StatelessWidget {
  const _ClockModule({
    required this.accent,
    required this.now,
    required this.locale,
  });

  final WallpaperAccent accent;
  final DateTime now;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final time = formatSystemBarClock(now);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: Motion.wallpaperReveal,
          curve: Motion.standard,
          style: ShellText.systemBarCaption.copyWith(
            color: accent.captionColor,
          ),
          child: Text(formatSystemBarDate(now, locale)),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: Motion.cardSettle,
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.25),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Text(
            time,
            key: ValueKey<String>(time),
            style: ShellText.systemBarValue,
          ),
        ),
      ],
    );
  }
}

/// One load meter: a caption tag naming the source, a sparkline of the recent
/// history, the animated percentage, and an optional direct sensor reading.
/// Identity comes from the tag, never from the line color alone.
class _MeterModule extends StatelessWidget {
  const _MeterModule({
    required this.accent,
    required this.label,
    required this.series,
  });

  final WallpaperAccent accent;
  final String label;
  final LoadSeries series;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: Motion.wallpaperReveal,
          curve: Motion.standard,
          style: ShellText.systemBarCaption.copyWith(
            color: accent.captionColor,
          ),
          child: Text(label),
        ),
        const SizedBox(width: 6),
        RepaintBoundary(
          child: CustomPaint(
            size: const Size(38, 14),
            painter: _SparklinePainter(
              history: series.history,
              accent: accent.color,
            ),
          ),
        ),
        const SizedBox(width: 7),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: series.current ?? 0.0),
          duration: Motion.pill,
          curve: Motion.standard,
          builder: (context, value, _) => SizedBox(
            width: 34,
            child: Text.rich(
              TextSpan(
                text: '${(value * 100).round()}',
                style: ShellText.systemBarValue,
                children: [
                  TextSpan(
                    text: '%',
                    style: ShellText.systemBarCaption.copyWith(
                      color: accent.captionColor,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
        ),
        if (series.temperatureC case final temperature?) ...[
          const SizedBox(width: 7),
          _TemperatureValue(accent: accent, temperatureC: temperature),
        ],
      ],
    );
  }
}

class _TemperatureValue extends StatelessWidget {
  const _TemperatureValue({required this.accent, required this.temperatureC});

  final WallpaperAccent accent;
  final double temperatureC;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: '${temperatureC.round()}',
        style: ShellText.systemBarValue,
        children: [
          TextSpan(
            text: '°C',
            style: ShellText.systemBarCaption.copyWith(
              color: accent.captionColor,
            ),
          ),
        ],
      ),
      maxLines: 1,
    );
  }
}

/// A borderless translucent pill hosting one system bar module. The softly
/// top-lit gradient animates between wallpaper accents at the wallpaper
/// reveal's pace so the bar re-themes as part of the same gesture.
class _SystemBarCard extends StatelessWidget {
  const _SystemBarCard({required this.accent, required this.child});

  final WallpaperAccent accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.wallpaperReveal,
      curve: Motion.standard,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.cardFillTop, accent.cardFill],
        ),
        borderRadius: const BorderRadius.all(Radius.circular(999)),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// One-shot mount transition for a pill: it springs in from the trailing
/// edge, staggered by [index], while its main-axis extent grows so the
/// neighbouring pills glide instead of jumping. Costs nothing once settled.
class _SystemBarEntrance extends StatefulWidget {
  const _SystemBarEntrance({
    required this.index,
    required this.horizontal,
    required this.child,
    super.key,
  });

  final int index;
  final bool horizontal;
  final Widget child;

  @override
  State<_SystemBarEntrance> createState() => _SystemBarEntranceState();
}

class _SystemBarEntranceState extends State<_SystemBarEntrance>
    with SingleTickerProviderStateMixin {
  static const double _slideDistance = 12.0;
  static const Duration _stagger = Duration(milliseconds: 60);

  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(_stagger * widget.index, () {
      if (mounted) {
        springTo(_controller, 1.0, telemetryLabel: 'system_bar_entrance');
      }
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final travel = (1.0 - t) * _slideDistance;
        return Align(
          alignment: widget.horizontal
              ? Alignment.centerRight
              : Alignment.bottomCenter,
          widthFactor: widget.horizontal ? unit(t) : null,
          heightFactor: widget.horizontal ? null : unit(t),
          child: Opacity(
            opacity: unit(t),
            child: Transform.translate(
              offset: widget.horizontal
                  ? Offset(travel, 0.0)
                  : Offset(0.0, travel),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Paints the CPU load history as an accent polyline over a gradient fill.
/// The newest sample hugs the trailing edge and the line slides left as the
/// window fills. Plain path drawing only — no mask filters, no save layers.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.history, required this.accent});

  final List<double> history;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final points = sparklinePoints(history, size);
    if (points.length < 2) {
      return;
    }
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      line.lineTo(point.dx, point.dy);
    }
    final fill = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.35),
            accent.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.history != history || oldDelegate.accent != accent;
  }
}

/// Maps [history] (oldest first, 0-1 values) onto sparkline points inside
/// [size]. The newest sample sits on the right edge; a partial history leaves
/// the left side empty so the line grows leftward as samples arrive.
@visibleForTesting
List<Offset> sparklinePoints(List<double> history, Size size) {
  if (history.isEmpty || size.isEmpty) {
    return const <Offset>[];
  }
  final step = size.width / (LoadSeries.capacity - 1);
  return List<Offset>.generate(history.length, (index) {
    final fromEnd = history.length - 1 - index;
    return Offset(
      size.width - fromEnd * step,
      size.height * (1.0 - history[index].clamp(0.0, 1.0)),
    );
  }, growable: false);
}

String formatSystemBarClock(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// Locale-aware compact date (`Dom 20 Lug`) for the clock pill caption.
String formatSystemBarDate(DateTime time, String locale) {
  return ShellClockInfo.shortDate(time, locale);
}
