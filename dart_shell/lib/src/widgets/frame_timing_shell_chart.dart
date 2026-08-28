part of 'shell_frame_time_overlay.dart';

class _FrameTimeBucket {
  const _FrameTimeBucket({
    required this.averageMs,
    required this.peakMs,
    required this.buildMs,
    required this.rasterMs,
    required this.gapMs,
    required this.frameCount,
    required this.overBudgetFrames,
  });

  const _FrameTimeBucket.empty()
    : averageMs = 0,
      peakMs = 0,
      buildMs = 0,
      rasterMs = 0,
      gapMs = null,
      frameCount = 0,
      overBudgetFrames = 0;

  final double averageMs;
  final double peakMs;
  final double buildMs;
  final double rasterMs;
  final double? gapMs;
  final int frameCount;
  final int overBudgetFrames;
}

class _ShellFrameStats {
  const _ShellFrameStats({
    required this.samples,
    required this.refreshRate,
    required this.budgetMs,
    required this.frameMs,
    required this.buildMs,
    required this.rasterMs,
    required this.gapMs,
    required this.averageMs,
    required this.maxMs,
    required this.overBudgetFrames,
  });

  const _ShellFrameStats.empty()
    : samples = const <_FrameTimeBucket>[],
      refreshRate = 0,
      budgetMs = 0,
      frameMs = 0,
      buildMs = 0,
      rasterMs = 0,
      gapMs = null,
      averageMs = 0,
      maxMs = 0,
      overBudgetFrames = 0;

  final List<_FrameTimeBucket> samples;
  final double refreshRate;
  final double budgetMs;
  final double frameMs;
  final double buildMs;
  final double rasterMs;
  final double? gapMs;
  final double averageMs;
  final double maxMs;
  final int overBudgetFrames;
}

class _ShellFrameTimePainter extends CustomPainter {
  const _ShellFrameTimePainter({
    required this.stats,
    required this.l10n,
    required this.colors,
    required this.cornerRadiusScale,
  });

  final _ShellFrameStats stats;
  final AppLocalizations l10n;
  final ShellColorScheme colors;
  final double cornerRadiusScale;

  TextStyle get _labelStyle => TextStyle(
    color: colors.textSecondary,
    fontSize: 9,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
  );
  TextStyle get _metricStyle => TextStyle(
    color: colors.textPrimary,
    fontSize: 10,
    height: 1,
    fontWeight: FontWeight.w600,
    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final panel = RRect.fromRectAndRadius(
      bounds,
      Radius.circular(10 * cornerRadiusScale),
    );
    canvas.drawRRect(panel, Paint()..color = colors.panelBackground);
    canvas.drawRRect(
      panel.deflate(0.5),
      Paint()
        ..color = colors.hairline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final hasSamples = stats.samples.isNotEmpty;
    _paintText(
      canvas,
      hasSamples
          ? l10n.frameShellRendering(stats.refreshRate.round())
          : l10n.frameShellWaiting,
      const Offset(10, 9),
      _labelStyle,
    );
    _paintText(
      canvas,
      hasSamples
          ? l10n.frameMilliseconds(stats.frameMs.toStringAsFixed(1))
          : l10n.frameMillisecondsUnavailable,
      Offset(size.width - 10, 7),
      _metricStyle.copyWith(
        color: _frameColor(colors, stats.frameMs, stats.budgetMs),
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
      align: TextAlign.right,
    );

    final gap = stats.gapMs;
    _paintText(
      canvas,
      l10n.frameShellPhases(
        stats.buildMs.toStringAsFixed(1),
        stats.rasterMs.toStringAsFixed(1),
        gap == null ? l10n.valueUnavailable : gap.toStringAsFixed(1),
      ),
      const Offset(10, 28),
      _metricStyle,
    );
    _paintText(
      canvas,
      l10n.frameShellStats(
        stats.averageMs.toStringAsFixed(1),
        stats.maxMs.toStringAsFixed(1),
        stats.overBudgetFrames,
      ),
      const Offset(10, 42),
      _labelStyle,
    );

    _paintGraph(
      canvas,
      Rect.fromLTRB(10, 58, size.width - 10, size.height - 9),
    );
  }

  void _paintGraph(Canvas canvas, Rect rect) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(4 * cornerRadiusScale)),
      Paint()..color = colors.background.withValues(alpha: 0.62),
    );
    if (stats.samples.isEmpty) {
      return;
    }

    // A fixed scale stops one spike from visually rewriting the entire chart.
    // Values beyond two display intervals are clipped at the top, while their
    // raw magnitude remains visible in MAX and OVER.
    final scaleMax = stats.budgetMs * 2;
    final budgetY = _graphY(stats.budgetMs, rect, scaleMax);
    canvas.drawLine(
      Offset(rect.left, budgetY),
      Offset(rect.right, budgetY),
      Paint()
        ..color = colors.performanceWarning.withValues(alpha: 0.55)
        ..strokeWidth = 1,
    );

    final path = Path();
    final denominator = math.max(
      1,
      _ShellFrameTimeOverlayState._historySize - 1,
    );
    for (var i = 0; i < stats.samples.length; i += 1) {
      final sample = stats.samples[i];
      final x =
          rect.right -
          (stats.samples.length - 1 - i) * rect.width / denominator;
      final y = _graphY(sample.averageMs, rect, scaleMax);

      // Keep short spikes visible without letting them dominate the smoothed
      // average line or rescale older history.
      if (sample.peakMs > sample.averageMs * 1.08) {
        canvas.drawLine(
          Offset(x, y),
          Offset(x, _graphY(sample.peakMs, rect, scaleMax)),
          Paint()
            ..color = _frameColor(
              colors,
              sample.peakMs,
              stats.budgetMs,
            ).withValues(alpha: 0.58)
            ..strokeWidth = 1,
        );
      }

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _frameColor(colors, stats.frameMs, stats.budgetMs)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  static double _graphY(double value, Rect rect, double scaleMax) {
    final t = (value / scaleMax).clamp(0.0, 1.0).toDouble();
    return rect.bottom - rect.height * t;
  }

  static void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == TextAlign.right ? offset.dx - painter.width : offset.dx;
    painter.paint(canvas, Offset(dx, offset.dy));
  }

  @override
  bool shouldRepaint(covariant _ShellFrameTimePainter oldDelegate) {
    return oldDelegate.stats != stats ||
        oldDelegate.l10n.localeName != l10n.localeName ||
        oldDelegate.colors != colors ||
        oldDelegate.cornerRadiusScale != cornerRadiusScale;
  }
}

Color _frameColor(ShellColorScheme colors, double frameMs, double budgetMs) {
  if (frameMs <= 0 || budgetMs <= 0) {
    return colors.textSecondary;
  }
  if (frameMs > budgetMs * 2) {
    return colors.performanceBad;
  }
  if (frameMs > budgetMs) {
    return colors.performanceWarning;
  }
  return colors.performanceGood;
}
