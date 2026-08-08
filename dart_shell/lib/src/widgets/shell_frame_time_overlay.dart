import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature, FramePhase, FrameTiming, TimingsCallback;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../config/startup_environment.dart';
import '../localization/denial_localizations.dart';
import '../models/denial_window.dart';
import '../theme/tokens.dart';

/// Diagnostics are opt-in: even a rate-limited frame overlay participates in
/// frame scheduling and must not tax the production shell it is measuring.
class ShellFrameTimingOptions {
  const ShellFrameTimingOptions({
    required this.showOverlay,
    required this.showImportedTextureCharts,
  });

  final bool showOverlay;
  final bool showImportedTextureCharts;
}

final shellFrameTimingOptionsProvider = Provider<ShellFrameTimingOptions>((
  ref,
) {
  final environment = ref.watch(startupEnvironmentProvider);
  final showOverlay = environment.flag('DENIA_FRAME_TIMING_OVERLAY');
  return ShellFrameTimingOptions(
    showOverlay: showOverlay,
    showImportedTextureCharts:
        showOverlay &&
        environment.flag(
          'DENIA_IMPORTED_FRAME_TIMING_OVERLAY',
          defaultValue: true,
        ),
  );
});

/// Owns the shell chart and one independent chart for every imported texture.
///
/// Imported callback-to-commit timings arrive already bucketed by the
/// compositor, so diagnostics cross the platform channel only five times per
/// second per active surface.
class ShellFrameTimingOverlayStack extends StatefulWidget {
  const ShellFrameTimingOverlayStack({
    required this.windows,
    required this.showImportedTextureCharts,
    super.key,
  });

  final List<DenialWindow> windows;
  final bool showImportedTextureCharts;

  @override
  State<ShellFrameTimingOverlayStack> createState() =>
      _ShellFrameTimingOverlayStackState();
}

class _ShellFrameTimingOverlayStackState
    extends State<ShellFrameTimingOverlayStack> {
  static const String _timingChannel = 'denial/imported_frame_timing';
  static const String _controlChannel = 'denial/imported_frame_timing_control';
  static const int _messageBytes = 7 * 8;
  static final Future<ByteData?> _emptyResponse = SynchronousFuture<ByteData?>(
    null,
  );

  final Map<int, _ImportedFrameTimingSampler> _samplers = {};
  bool _channelStarted = false;
  int _budgetUs = (1000000 / 60).round();

  @override
  void initState() {
    super.initState();
    _syncSamplers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.showImportedTextureCharts) {
      return;
    }

    final reportedRate = View.of(context).display.refreshRate;
    final refreshRate = reportedRate.isFinite && reportedRate > 0
        ? reportedRate
        : 60.0;
    final nextBudgetUs = (1000000 / refreshRate).round();
    final budgetChanged = nextBudgetUs != _budgetUs;
    _budgetUs = nextBudgetUs;
    for (final sampler in _samplers.values) {
      sampler.updateBudget(_budgetUs / 1000);
    }

    if (!_channelStarted) {
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _timingChannel,
        _handleTimingMessage,
      );
      _channelStarted = true;
      _sendTimingControl(enabled: true);
    } else if (budgetChanged) {
      _sendTimingControl(enabled: true);
    }
  }

  @override
  void didUpdateWidget(covariant ShellFrameTimingOverlayStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.windows != widget.windows) {
      _syncSamplers();
    }
  }

  @override
  void dispose() {
    if (_channelStarted) {
      _sendTimingControl(enabled: false);
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _timingChannel,
        null,
      );
    }
    for (final sampler in _samplers.values) {
      sampler.dispose();
    }
    _samplers.clear();
    super.dispose();
  }

  void _syncSamplers() {
    if (!widget.showImportedTextureCharts) {
      return;
    }

    final activeSurfaceIds = widget.windows
        .map((window) => window.surfaceId)
        .toSet();
    final removedSurfaceIds = _samplers.keys
        .where((surfaceId) => !activeSurfaceIds.contains(surfaceId))
        .toList(growable: false);
    for (final surfaceId in removedSurfaceIds) {
      _samplers.remove(surfaceId)?.dispose();
    }
    for (final surfaceId in activeSurfaceIds) {
      _samplers.putIfAbsent(
        surfaceId,
        () => _ImportedFrameTimingSampler(_budgetUs / 1000),
      );
    }
  }

  void _sendTimingControl({required bool enabled}) {
    final data = ByteData(1 + 8)
      ..setUint8(0, enabled ? 1 : 0)
      ..setUint64(1, _budgetUs, Endian.little);
    ServicesBinding.instance.defaultBinaryMessenger
        .send(_controlChannel, data)
        ?.catchError((Object _) => null);
  }

  Future<ByteData?> _handleTimingMessage(ByteData? data) {
    if (data == null || data.lengthInBytes < _messageBytes) {
      return _emptyResponse;
    }

    final surfaceId = data.getUint64(0, Endian.little);
    final sampler = _samplers[surfaceId];
    if (sampler == null) {
      return _emptyResponse;
    }

    sampler.addBucket(
      _ImportedFrameTimeBucket(
        averageMs: data.getUint64(24, Endian.little) / 1000,
        peakMs: data.getUint64(32, Endian.little) / 1000,
        frameCount: data.getUint64(40, Endian.little),
        overBudgetFrames: data.getUint64(48, Endian.little),
      ),
    );
    return _emptyResponse;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ShellFrameTimeOverlay(),
            if (widget.showImportedTextureCharts)
              for (final window in widget.windows)
                if (_samplers[window.surfaceId] case final sampler?) ...[
                  const SizedBox(height: 6),
                  _ImportedTextureFrameTimeOverlay(
                    key: ValueKey(window.surfaceId),
                    title: localizedWindowTitle(context, window),
                    sampler: sampler,
                  ),
                ],
          ],
        ),
      ),
    );
  }
}

/// A low-overhead view of the embedded shell engine's real frame timings.
///
/// Unlike a [Ticker]-based meter, this widget does not manufacture a frame on
/// every vsync. It observes completed engine frames and refreshes its own small
/// repaint boundary at most five times per second while other work is active.
class ShellFrameTimeOverlay extends StatefulWidget {
  const ShellFrameTimeOverlay({super.key});

  @override
  State<ShellFrameTimeOverlay> createState() => _ShellFrameTimeOverlayState();
}

class _ShellFrameTimeOverlayState extends State<ShellFrameTimeOverlay> {
  static const int _historySize = 60;
  static const Duration _bucketDuration = Duration(milliseconds: 200);
  static const double _idleGapInFrames = 8;
  static const double _smoothingAlpha = 0.24;

  late final TimingsCallback _timingsCallback = _handleTimings;
  final List<_FrameTimeBucket> _history = List<_FrameTimeBucket>.filled(
    _historySize,
    const _FrameTimeBucket.empty(),
  );

  _ShellFrameStats _stats = const _ShellFrameStats.empty();
  int _historyWriteIndex = 0;
  int _historyCount = 0;
  int? _bucketStartVsyncUs;
  int? _previousVsyncUs;
  bool _ignoreNextTiming = false;
  bool _hasPublished = false;
  double _refreshRate = 60;
  double _budgetMs = 1000 / 60;

  double _bucketFrameTotalMs = 0;
  double _bucketBuildTotalMs = 0;
  double _bucketRasterTotalMs = 0;
  double _bucketGapTotalMs = 0;
  double _bucketPeakMs = 0;
  int _bucketFrameCount = 0;
  int _bucketGapCount = 0;
  int _bucketOverBudget = 0;

  double _smoothedFrameMs = 0;
  double _smoothedBuildMs = 0;
  double _smoothedRasterMs = 0;
  double? _smoothedGapMs;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reportedRate = View.of(context).display.refreshRate;
    _refreshRate = reportedRate.isFinite && reportedRate > 0
        ? reportedRate
        : 60;
    _budgetMs = 1000 / _refreshRate;
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timingsCallback);
    super.dispose();
  }

  void _handleTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) {
      return;
    }

    var observedFrame = false;
    var completedBucket = false;
    for (final timing in timings) {
      if (_ignoreNextTiming) {
        // The repaint requested by the previous publication is measurement
        // overhead, not application work. Ignoring it also prevents a delayed
        // timing report from turning the overlay into a self-driving loop.
        _ignoreNextTiming = false;
        _previousVsyncUs = timing.timestampInMicroseconds(
          FramePhase.vsyncStart,
        );
        continue;
      }
      observedFrame = true;
      final vsyncUs = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      final bucketStartVsyncUs = _bucketStartVsyncUs;
      if (bucketStartVsyncUs == null) {
        _bucketStartVsyncUs = vsyncUs;
      } else if (vsyncUs - bucketStartVsyncUs >=
          _bucketDuration.inMicroseconds) {
        completedBucket = _commitBucket() || completedBucket;
        _bucketStartVsyncUs = vsyncUs;
      }

      final previousVsyncUs = _previousVsyncUs;
      _previousVsyncUs = vsyncUs;

      if (previousVsyncUs != null) {
        final gapMs = (vsyncUs - previousVsyncUs) / 1000;
        if (gapMs > 0 && gapMs <= _budgetMs * _idleGapInFrames) {
          _bucketGapTotalMs += gapMs;
          _bucketGapCount += 1;
        }
      }

      // With a compositor-owned vsync pipeline, FrameTiming.totalSpan also
      // contains scheduler/presentation phases and is not render cost. Build
      // plus raster is the engine work the user is asking this card to show.
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
      final frameMs = buildMs + rasterMs;
      _bucketFrameTotalMs += frameMs;
      _bucketBuildTotalMs += buildMs;
      _bucketRasterTotalMs += rasterMs;
      _bucketPeakMs = math.max(_bucketPeakMs, frameMs);
      _bucketFrameCount += 1;
      if (frameMs > _budgetMs) {
        _bucketOverBudget += 1;
      }
    }

    if (!observedFrame || !mounted) {
      return;
    }

    if (completedBucket || !_hasPublished) {
      _publishStats();
    }
  }

  bool _commitBucket() {
    if (_bucketFrameCount == 0) {
      return false;
    }

    final bucket = _currentBucket();
    _history[_historyWriteIndex] = bucket;
    _historyWriteIndex = (_historyWriteIndex + 1) % _historySize;
    _historyCount = math.min(_historyCount + 1, _historySize);

    _smoothedFrameMs = _smooth(_smoothedFrameMs, bucket.averageMs);
    _smoothedBuildMs = _smooth(_smoothedBuildMs, bucket.buildMs);
    _smoothedRasterMs = _smooth(_smoothedRasterMs, bucket.rasterMs);
    if (bucket.gapMs case final gapMs?) {
      _smoothedGapMs = _smoothedGapMs == null
          ? gapMs
          : _smooth(_smoothedGapMs!, gapMs);
    }

    _bucketFrameTotalMs = 0;
    _bucketBuildTotalMs = 0;
    _bucketRasterTotalMs = 0;
    _bucketGapTotalMs = 0;
    _bucketPeakMs = 0;
    _bucketFrameCount = 0;
    _bucketGapCount = 0;
    _bucketOverBudget = 0;
    return true;
  }

  _FrameTimeBucket _currentBucket() {
    return _FrameTimeBucket(
      averageMs: _bucketFrameTotalMs / _bucketFrameCount,
      peakMs: _bucketPeakMs,
      buildMs: _bucketBuildTotalMs / _bucketFrameCount,
      rasterMs: _bucketRasterTotalMs / _bucketFrameCount,
      gapMs: _bucketGapCount == 0 ? null : _bucketGapTotalMs / _bucketGapCount,
      frameCount: _bucketFrameCount,
      overBudgetFrames: _bucketOverBudget,
    );
  }

  double _smooth(double previous, double current) {
    if (previous <= 0) {
      return current;
    }
    return previous + (current - previous) * _smoothingAlpha;
  }

  void _publishStats() {
    final buckets = <_FrameTimeBucket>[];
    var weightedTotalMs = 0.0;
    var totalFrames = 0;
    var maxMs = 0.0;
    var overBudget = 0;
    final first = (_historyWriteIndex - _historyCount) % _historySize;

    for (var i = 0; i < _historyCount; i += 1) {
      final bucket = _history[(first + i) % _historySize];
      buckets.add(bucket);
      weightedTotalMs += bucket.averageMs * bucket.frameCount;
      totalFrames += bucket.frameCount;
      maxMs = math.max(maxMs, bucket.peakMs);
      overBudget += bucket.overBudgetFrames;
    }

    // Give the very first rendered frame something useful to display. Once a
    // full 200 ms bucket exists, only completed buckets enter the chart.
    if (buckets.isEmpty && _bucketFrameCount > 0) {
      final bucket = _currentBucket();
      buckets.add(bucket);
      weightedTotalMs = bucket.averageMs * bucket.frameCount;
      totalFrames = bucket.frameCount;
      maxMs = bucket.peakMs;
      overBudget = bucket.overBudgetFrames;
    }

    final latest = buckets.last;
    final next = _ShellFrameStats(
      samples: buckets,
      refreshRate: _refreshRate,
      budgetMs: _budgetMs,
      frameMs: _historyCount == 0 ? latest.averageMs : _smoothedFrameMs,
      buildMs: _historyCount == 0 ? latest.buildMs : _smoothedBuildMs,
      rasterMs: _historyCount == 0 ? latest.rasterMs : _smoothedRasterMs,
      gapMs: _historyCount == 0 ? latest.gapMs : _smoothedGapMs,
      averageMs: totalFrames == 0 ? 0 : weightedTotalMs / totalFrames,
      maxMs: maxMs,
      overBudgetFrames: overBudget,
    );

    _hasPublished = true;
    _ignoreNextTiming = true;
    setState(() {
      _stats = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox(
            width: 248,
            height: 92,
            child: CustomPaint(
              painter: _ShellFrameTimePainter(
                stats: _stats,
                l10n: context.l10n,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
  });

  final String title;
  final _ImportedFrameStats stats;
  final AppLocalizations l10n;

  static const TextStyle _labelStyle = TextStyle(
    color: ShellColors.textSecondary,
    fontSize: 9,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
  static const TextStyle _metricStyle = TextStyle(
    color: ShellColors.textPrimary,
    fontSize: 10,
    height: 1,
    fontWeight: FontWeight.w600,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final panel = RRect.fromRectAndRadius(bounds, const Radius.circular(10));
    canvas.drawRRect(panel, Paint()..color = ShellColors.panelBackground);
    canvas.drawRRect(
      panel.deflate(0.5),
      Paint()
        ..color = ShellColors.hairline
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
        color: _frameColor(stats.frameMs, stats.budgetMs),
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
      Paint()..color = ShellColors.background.withValues(alpha: 0.62),
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
        ..color = ShellColors.performanceWarning.withValues(alpha: 0.55)
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
        ..color = _frameColor(stats.frameMs, stats.budgetMs)
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
        oldDelegate.l10n.localeName != l10n.localeName;
  }
}

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
  const _ShellFrameTimePainter({required this.stats, required this.l10n});

  final _ShellFrameStats stats;
  final AppLocalizations l10n;

  static const TextStyle _labelStyle = TextStyle(
    color: ShellColors.textSecondary,
    fontSize: 9,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
  static const TextStyle _metricStyle = TextStyle(
    color: ShellColors.textPrimary,
    fontSize: 10,
    height: 1,
    fontWeight: FontWeight.w600,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final panel = RRect.fromRectAndRadius(bounds, const Radius.circular(10));
    canvas.drawRRect(panel, Paint()..color = ShellColors.panelBackground);
    canvas.drawRRect(
      panel.deflate(0.5),
      Paint()
        ..color = ShellColors.hairline
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
        color: _frameColor(stats.frameMs, stats.budgetMs),
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
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = ShellColors.background.withValues(alpha: 0.62),
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
        ..color = ShellColors.performanceWarning.withValues(alpha: 0.55)
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
        ..color = _frameColor(stats.frameMs, stats.budgetMs)
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
        oldDelegate.l10n.localeName != l10n.localeName;
  }
}

Color _frameColor(double frameMs, double budgetMs) {
  if (frameMs <= 0 || budgetMs <= 0) {
    return ShellColors.textSecondary;
  }
  if (frameMs > budgetMs * 2) {
    return ShellColors.performanceBad;
  }
  if (frameMs > budgetMs) {
    return ShellColors.performanceWarning;
  }
  return ShellColors.performanceGood;
}
