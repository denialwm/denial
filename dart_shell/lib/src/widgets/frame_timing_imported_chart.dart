part of 'shell_frame_time_overlay.dart';

class _ImportedTextureFrameTimeOverlay extends StatelessWidget {
  const _ImportedTextureFrameTimeOverlay({
    required this.title,
    required this.sampler,
    super.key,
  });

  final String title;
  final _ImportedFrameTimingSampler sampler;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: sampler,
        builder: (context, child) {
          return SizedBox(
            width: 248,
            height: 78,
            child: CustomPaint(
              painter: _ImportedFrameTimePainter(
                title: title,
                stats: sampler.stats,
                l10n: context.l10n,
                colors: context.shellColors,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ImportedFrameTimingSampler extends ChangeNotifier {
  _ImportedFrameTimingSampler(double budgetMs)
    : _budgetMs = budgetMs,
      _stats = _ImportedFrameStats.empty(budgetMs);

  static const int historySize = 60;
  static const double _smoothingAlpha = 0.24;

  final List<_ImportedFrameTimeBucket> _history =
      List<_ImportedFrameTimeBucket>.filled(
        historySize,
        const _ImportedFrameTimeBucket.empty(),
      );

  double _budgetMs;
  _ImportedFrameStats _stats;
  int _historyWriteIndex = 0;
  int _historyCount = 0;
  double _smoothedFrameMs = 0;

  _ImportedFrameStats get stats => _stats;

  void updateBudget(double budgetMs) {
    if ((budgetMs - _budgetMs).abs() < 0.001) {
      return;
    }
    _budgetMs = budgetMs;
    _publish();
  }

  void addBucket(_ImportedFrameTimeBucket bucket) {
    if (bucket.frameCount <= 0 || bucket.averageMs <= 0) {
      return;
    }

    _history[_historyWriteIndex] = bucket;
    _historyWriteIndex = (_historyWriteIndex + 1) % historySize;
    _historyCount = math.min(_historyCount + 1, historySize);
    _smoothedFrameMs = _smoothedFrameMs <= 0
        ? bucket.averageMs
        : _smoothedFrameMs +
              (bucket.averageMs - _smoothedFrameMs) * _smoothingAlpha;
    _publish();
  }

  void _publish() {
    if (_historyCount == 0) {
      _stats = _ImportedFrameStats.empty(_budgetMs);
      notifyListeners();
      return;
    }

    final samples = <_ImportedFrameTimeBucket>[];
    var weightedTotalMs = 0.0;
    var totalFrames = 0;
    var maxMs = 0.0;
    var overBudgetFrames = 0;
    final first = (_historyWriteIndex - _historyCount) % historySize;
    for (var i = 0; i < _historyCount; i += 1) {
      final sample = _history[(first + i) % historySize];
      samples.add(sample);
      weightedTotalMs += sample.averageMs * sample.frameCount;
      totalFrames += sample.frameCount;
      maxMs = math.max(maxMs, sample.peakMs);
      overBudgetFrames += sample.overBudgetFrames;
    }

    _stats = _ImportedFrameStats(
      samples: samples,
      budgetMs: _budgetMs,
      frameMs: _smoothedFrameMs,
      averageMs: weightedTotalMs / totalFrames,
      maxMs: maxMs,
      sampleCount: totalFrames,
      overBudgetFrames: overBudgetFrames,
    );
    notifyListeners();
  }
}

class _ImportedFrameTimeBucket {
  const _ImportedFrameTimeBucket({
    required this.averageMs,
    required this.peakMs,
    required this.frameCount,
    required this.overBudgetFrames,
  });

  const _ImportedFrameTimeBucket.empty()
    : averageMs = 0,
      peakMs = 0,
      frameCount = 0,
      overBudgetFrames = 0;

  final double averageMs;
  final double peakMs;
  final int frameCount;
  final int overBudgetFrames;
}

class _ImportedFrameStats {
  const _ImportedFrameStats({
    required this.samples,
    required this.budgetMs,
    required this.frameMs,
    required this.averageMs,
    required this.maxMs,
    required this.sampleCount,
    required this.overBudgetFrames,
  });

  const _ImportedFrameStats.empty(this.budgetMs)
    : samples = const <_ImportedFrameTimeBucket>[],
      frameMs = 0,
      averageMs = 0,
      maxMs = 0,
      sampleCount = 0,
      overBudgetFrames = 0;

  final List<_ImportedFrameTimeBucket> samples;
  final double budgetMs;
  final double frameMs;
  final double averageMs;
  final double maxMs;
  final int sampleCount;
  final int overBudgetFrames;
}

class _ImportedFrameTimePainter extends CustomPainter {
  const _ImportedFrameTimePainter({
    required this.title,
    required this.stats,
    required this.l10n,
    required this.colors,
  });

  final String title;
  final _ImportedFrameStats stats;
  final AppLocalizations l10n;
  final ShellColorScheme colors;

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
    final panel = RRect.fromRectAndRadius(bounds, const Radius.circular(10));
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
          ? l10n.frameAppRendering(title.toUpperCase())
          : l10n.frameAppWaiting(title),
      const Offset(10, 9),
      _labelStyle,
      maxWidth: size.width - 112,
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
    _paintText(
      canvas,
      hasSamples
          ? l10n.frameImportedStats(
              stats.averageMs.toStringAsFixed(1),
              stats.maxMs.toStringAsFixed(1),
              stats.overBudgetFrames,
              stats.sampleCount,
            )
          : l10n.frameImportedStatsUnavailable,
      const Offset(10, 28),
      _metricStyle,
      maxWidth: size.width - 20,
    );

    _paintGraph(
      canvas,
      Rect.fromLTRB(10, 44, size.width - 10, size.height - 9),
    );
  }

  void _paintGraph(Canvas canvas, Rect rect) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = colors.background.withValues(alpha: 0.62),
    );
    if (stats.samples.isEmpty) {
      return;
    }

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
      _ImportedFrameTimingSampler.historySize - 1,
    );
    for (var i = 0; i < stats.samples.length; i += 1) {
      final sample = stats.samples[i];
      final x =
          rect.right -
          (stats.samples.length - 1 - i) * rect.width / denominator;
      final y = _graphY(sample.averageMs, rect, scaleMax);

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
    double? maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      ellipsis: '…',
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth ?? double.infinity);
    final dx = align == TextAlign.right ? offset.dx - painter.width : offset.dx;
    painter.paint(canvas, Offset(dx, offset.dy));
  }

  @override
  bool shouldRepaint(covariant _ImportedFrameTimePainter oldDelegate) {
    return oldDelegate.title != title ||
        oldDelegate.stats != stats ||
        oldDelegate.l10n.localeName != l10n.localeName ||
        oldDelegate.colors != colors;
  }
}
