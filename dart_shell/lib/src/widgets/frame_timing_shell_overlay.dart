part of 'shell_frame_time_overlay.dart';

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
                colors: context.shellColors,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
