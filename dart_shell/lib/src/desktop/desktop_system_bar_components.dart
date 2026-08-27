part of 'desktop_system_bar.dart';

/// Date caption plus the ticking clock. The caption re-tints with the
/// wallpaper accent; minute changes crossfade with a small upward slide.
class _ClockModule extends StatelessWidget {
  const _ClockModule({required this.accent, required this.now});

  final WallpaperAccent accent;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final time = localizedTime(context, now);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: Motion.wallpaperReveal,
          curve: Motion.standard,
          style: ShellText.systemBarCaption.copyWith(
            color: accent.captionColor(context.shellTheme),
          ),
          child: Text(localizedShortDate(context, now)),
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

/// A compact battery gauge whose cell fills with the wallpaper accent. The
/// charging bolt is drawn inside the cell, leaving the module calm and
/// readable without spending horizontal space on a second status icon.
class _BatteryActionCard extends StatefulWidget {
  const _BatteryActionCard({
    required this.accent,
    required this.status,
    required this.onPressed,
  });

  final WallpaperAccent accent;
  final BatteryStatus status;
  final VoidCallback onPressed;

  @override
  State<_BatteryActionCard> createState() => _BatteryActionCardState();
}

class _BatteryActionCardState extends State<_BatteryActionCard> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final capacity = widget.status.capacity ?? 0;
    final state = widget.status.charging ? 'charging' : 'discharging';
    final statusLabel = localizedBatteryLine(context.l10n, state, capacity);
    return Semantics(
      button: true,
      label: '${context.l10n.batteryTitle}, $statusLabel',
      onTap: widget.onPressed,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: systemBarBatteryButtonKey,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            mouseCursor: ShellMouseCursors.link,
            splashFactory: NoSplash.splashFactory,
            overlayColor: WidgetStatePropertyAll(
              ShellMediaColors.transparentDark,
            ),
            onTap: widget.onPressed,
            onHover: (value) => setState(() => _hovered = value),
            onFocusChange: (value) => setState(() => _focused = value),
            child: _SystemBarCard(
              accent: widget.accent,
              highlighted: _hovered || _focused,
              focused: _focused,
              child: _BatteryModule(
                accent: widget.accent,
                status: widget.status,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatteryModule extends StatelessWidget {
  const _BatteryModule({required this.accent, required this.status});

  final WallpaperAccent accent;
  final BatteryStatus status;

  @override
  Widget build(BuildContext context) {
    final capacity = status.capacity ?? 0;
    final level = (capacity / 100).clamp(0.0, 1.0).toDouble();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: level),
          duration: Motion.pill,
          curve: Motion.standard,
          builder: (context, value, _) => RepaintBoundary(
            child: CustomPaint(
              size: const Size(24, 14),
              painter: _BatteryLevelPainter(
                level: value,
                charging: status.charging,
                accent: context.shellTheme.accent,
                outline: accent.captionColor(context.shellTheme),
                foreground: context.shellColors.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 7),
        SizedBox(
          width: 34,
          child: Text.rich(
            TextSpan(
              text: context.l10n.numberValue(capacity),
              style: context.shellTheme.text.systemBarValue,
              children: [
                TextSpan(
                  text: context.l10n.percentSign,
                  style: context.shellTheme.text.systemBarCaption.copyWith(
                    color: accent.captionColor(context.shellTheme),
                  ),
                ),
              ],
            ),
            textAlign: TextAlign.right,
            maxLines: 1,
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
            color: accent.captionColor(context.shellTheme),
          ),
          child: Text(label),
        ),
        const SizedBox(width: 6),
        RepaintBoundary(
          child: CustomPaint(
            size: const Size(38, 14),
            painter: _SparklinePainter(
              history: series.history,
              accent: context.shellTheme.accent,
            ),
          ),
        ),
        const SizedBox(width: 7),
        SizedBox(
          width: 34,
          child: Text.rich(
            TextSpan(
              text: context.l10n.numberValue(
                ((series.current ?? 0.0) * 100).round(),
              ),
              style: ShellText.systemBarValue,
              children: [
                TextSpan(
                  text: context.l10n.percentSign,
                  style: ShellText.systemBarCaption.copyWith(
                    color: accent.captionColor(context.shellTheme),
                  ),
                ),
              ],
            ),
            textAlign: TextAlign.right,
            maxLines: 1,
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
        text: context.l10n.numberValue(temperatureC.round()),
        style: ShellText.systemBarValue,
        children: [
          TextSpan(
            text: context.l10n.celsiusUnit,
            style: ShellText.systemBarCaption.copyWith(
              color: accent.captionColor(context.shellTheme),
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
  const _SystemBarCard({
    required this.accent,
    required this.child,
    this.highlighted = false,
    this.focused = false,
  });

  final WallpaperAccent accent;
  final Widget child;
  final bool highlighted;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(999));
    final theme = ShellTheme.of(context);
    final cardFillTop = accent.cardFillTop(theme);
    final cardFill = accent.cardFill(theme);
    final topFill = highlighted
        ? Color.lerp(cardFillTop, theme.accent, 0.12)!
        : cardFillTop;
    final bottomFill = highlighted
        ? Color.lerp(cardFill, theme.accent, 0.08)!
        : cardFill;
    return ShellBackdropBlur(
      borderRadius: radius,
      child: AnimatedContainer(
        duration: Motion.wallpaperReveal,
        curve: Motion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [theme.panelColor(topFill), theme.panelColor(bottomFill)],
          ),
          borderRadius: radius,
          border: focused
              ? Border.all(color: theme.accent.withValues(alpha: 0.78))
              : null,
        ),
        alignment: Alignment.center,
        child: child,
      ),
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

/// Draws a small battery silhouette with an animated charge fill and an
/// integrated bolt. All geometry is vector-based so the gauge stays crisp at
/// fractional desktop scale factors.
class _BatteryLevelPainter extends CustomPainter {
  const _BatteryLevelPainter({
    required this.level,
    required this.charging,
    required this.accent,
    required this.outline,
    required this.foreground,
  });

  final double level;
  final bool charging;
  final Color accent;
  final Color outline;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 1.25, size.width - 4.0, size.height - 2.5),
      const Radius.circular(3.0),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.35,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width - 2.55,
          size.height * 0.34,
          1.8,
          size.height * 0.32,
        ),
        const Radius.circular(0.8),
      ),
      Paint()..color = outline,
    );

    final fillBounds = Rect.fromLTWH(
      body.left + 2.0,
      body.top + 2.0,
      math.max(0.0, (body.width - 4.0) * level.clamp(0.0, 1.0)),
      body.height - 4.0,
    );
    if (fillBounds.width > 0.0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillBounds, const Radius.circular(1.5)),
        Paint()..color = accent,
      );
    }

    if (charging) {
      final center = body.center;
      final bolt = Path()
        ..moveTo(center.dx + 0.6, body.top + 1.7)
        ..lineTo(center.dx - 3.0, center.dy + 0.4)
        ..lineTo(center.dx - 0.6, center.dy + 0.4)
        ..lineTo(center.dx - 1.5, body.bottom - 1.6)
        ..lineTo(center.dx + 3.0, center.dy - 0.8)
        ..lineTo(center.dx + 0.5, center.dy - 0.8)
        ..close();
      canvas.drawPath(bolt, Paint()..color = foreground);
    }
  }

  @override
  bool shouldRepaint(covariant _BatteryLevelPainter oldDelegate) {
    return oldDelegate.level != level ||
        oldDelegate.charging != charging ||
        oldDelegate.accent != accent ||
        oldDelegate.outline != outline ||
        oldDelegate.foreground != foreground;
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
