import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Opt-in counters for the Dart-side stages of desktop window rendering.
///
/// Enable these counters together with Denial's native render diagnostics by
/// starting Denial with `DENIA_RENDER_AUDIT=1`. The timer does not schedule
/// Flutter frames; it only reports work that happened independently.
class DesktopWindowRenderTelemetry {
  DesktopWindowRenderTelemetry._();

  static bool _enabled = false;
  static final Stopwatch _clock = Stopwatch();
  static final Set<int> _knownWindows = <int>{};
  static final Map<int, int> _builds = <int, int>{};
  static final Map<int, int> _shadowPaints = <int, int>{};
  static final Map<int, int> _borderPaints = <int, int>{};
  static final Map<int, Size> _lastPaintSizes = <int, Size>{};
  static final Map<int, String> _labels = <int, String>{};
  static final Map<int, int> _textureIds = <int, int>{};
  static final RegExp _labelSeparators = RegExp(r'[\s,=]+');
  static final FrameTimingAuditInterval _frameTimings =
      FrameTimingAuditInterval();

  static void install({required bool enabled}) {
    if (_enabled || !enabled) {
      return;
    }
    _enabled = true;
    _clock.start();
    SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
    Timer.periodic(const Duration(seconds: 1), (_) => _report());
    _event('start');
  }

  static void recordWindowBuild({
    required int windowId,
    required int textureId,
    required String label,
  }) {
    if (!_enabled) {
      return;
    }
    _knownWindows.add(windowId);
    _labels[windowId] = _sanitizeLabel(label);
    _textureIds[windowId] = textureId;
    _builds.update(windowId, (count) => count + 1, ifAbsent: () => 1);
  }

  static void recordShadowPaint(int windowId, Size size) {
    if (!_enabled) {
      return;
    }
    _knownWindows.add(windowId);
    _lastPaintSizes[windowId] = size;
    _shadowPaints.update(windowId, (count) => count + 1, ifAbsent: () => 1);
  }

  static void recordBorderPaint(int windowId, Size size) {
    if (!_enabled) {
      return;
    }
    _knownWindows.add(windowId);
    _lastPaintSizes[windowId] = size;
    _borderPaints.update(windowId, (count) => count + 1, ifAbsent: () => 1);
  }

  static void _report() {
    final windows = _knownWindows.toList()..sort();
    _event(
      'dart_window_work',
      fields: <String, Object>{
        'windows': windows.length,
        'apps': _formatLabels(windows),
        'textures': _formatTextureIds(windows),
        'builds': _formatCounts(windows, _builds),
        'shadow_paints': _formatCounts(windows, _shadowPaints),
        'border_paints': _formatCounts(windows, _borderPaints),
        'sizes': _formatSizes(windows),
      },
    );
    _builds.clear();
    _shadowPaints.clear();
    _borderPaints.clear();

    final budgetUs = _frameBudgetUs();
    _event(
      'dart_frame_timing',
      fields: <String, Object>{
        'budget_us': budgetUs,
        'refresh_hz': (1000000 / budgetUs).toStringAsFixed(2),
        ..._frameTimings.takeReport(budgetUs: budgetUs),
      },
    );
  }

  static void _recordFrameTimings(List<FrameTiming> timings) {
    _frameTimings.record(timings);
  }

  static int _frameBudgetUs() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final reportedRate = views.isEmpty ? 60.0 : views.first.display.refreshRate;
    final refreshRate = reportedRate.isFinite && reportedRate > 0
        ? reportedRate
        : 60.0;
    return (1000000 / refreshRate).round();
  }

  static String _formatCounts(List<int> windows, Map<int, int> counts) {
    if (windows.isEmpty) {
      return '-';
    }
    return windows
        .map((windowId) => '$windowId:${counts[windowId] ?? 0}')
        .join(',');
  }

  static String _formatSizes(List<int> windows) {
    final values = <String>[];
    for (final windowId in windows) {
      final size = _lastPaintSizes[windowId];
      if (size != null) {
        values.add(
          '$windowId:${size.width.toStringAsFixed(0)}x'
          '${size.height.toStringAsFixed(0)}',
        );
      }
    }
    return values.isEmpty ? '-' : values.join(',');
  }

  static String _formatLabels(List<int> windows) {
    if (windows.isEmpty) {
      return '-';
    }
    return windows
        .map((windowId) => '$windowId:${_labels[windowId] ?? '-'}')
        .join(',');
  }

  static String _formatTextureIds(List<int> windows) {
    if (windows.isEmpty) {
      return '-';
    }
    return windows
        .map((windowId) => '$windowId:${_textureIds[windowId] ?? 0}')
        .join(',');
  }

  static String _sanitizeLabel(String value) {
    final label = value.trim();
    if (label.isEmpty) {
      return '-';
    }
    return label.replaceAll(_labelSeparators, '_');
  }

  static void _event(
    String event, {
    Map<String, Object> fields = const <String, Object>{},
  }) {
    final buffer = StringBuffer(
      'Denial render_audit source=dart ts_us=${_clock.elapsedMicroseconds} '
      'event=$event',
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

/// Exact per-interval Flutter frame samples used by the opt-in render audit.
///
/// This deliberately retains and sorts every sample in the reporting interval:
/// audit mode favors useful tail latency over observer overhead.
@visibleForTesting
class FrameTimingAuditInterval {
  final _TimingSamples _build = _TimingSamples();
  final _TimingSamples _raster = _TimingSamples();
  final _TimingSamples _rasterQueue = _TimingSamples();
  final _TimingSamples _engineWork = _TimingSamples();
  final _TimingSamples _vsyncOverhead = _TimingSamples();
  final _TimingSamples _totalSpan = _TimingSamples();
  final _TimingSamples _vsyncGap = _TimingSamples();
  int? _previousVsyncUs;

  void record(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildUs = timing.buildDuration.inMicroseconds;
      final rasterUs = timing.rasterDuration.inMicroseconds;
      final rasterQueueUs =
          timing.timestampInMicroseconds(FramePhase.rasterStart) -
          timing.timestampInMicroseconds(FramePhase.buildFinish);
      final vsyncUs = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      final previousVsyncUs = _previousVsyncUs;
      _previousVsyncUs = vsyncUs;

      _build.add(buildUs);
      _raster.add(rasterUs);
      _rasterQueue.add(rasterQueueUs < 0 ? 0 : rasterQueueUs);
      _engineWork.add(buildUs + rasterUs);
      _vsyncOverhead.add(timing.vsyncOverhead.inMicroseconds);
      _totalSpan.add(timing.totalSpan.inMicroseconds);
      if (previousVsyncUs != null && vsyncUs > previousVsyncUs) {
        _vsyncGap.add(vsyncUs - previousVsyncUs);
      }
    }
  }

  Map<String, Object> takeReport({required int budgetUs}) {
    final effectiveBudgetUs = budgetUs > 0 ? budgetUs : 16667;
    final report = <String, Object>{
      'frames': _build.length,
      ..._build.report('build'),
      ..._raster.report('raster'),
      ..._rasterQueue.report('raster_queue'),
      ..._engineWork.report('engine_work'),
      ..._vsyncOverhead.report('vsync_overhead'),
      ..._totalSpan.report('total_span'),
      ..._vsyncGap.report('vsync_gap'),
      'engine_over_budget': _engineWork.countAbove(effectiveBudgetUs),
      'total_span_over_budget': _totalSpan.countAbove(effectiveBudgetUs),
      'vsync_gap_over_budget': _vsyncGap.countAbove(effectiveBudgetUs),
    };
    _build.clear();
    _raster.clear();
    _rasterQueue.clear();
    _engineWork.clear();
    _vsyncOverhead.clear();
    _totalSpan.clear();
    _vsyncGap.clear();
    return report;
  }
}

class _TimingSamples {
  final List<int> _values = <int>[];
  int _total = 0;
  int _max = 0;

  int get length => _values.length;

  void add(int microseconds) {
    final value = microseconds < 0 ? 0 : microseconds;
    _values.add(value);
    _total += value;
    if (value > _max) {
      _max = value;
    }
  }

  int countAbove(int threshold) {
    return _values.where((value) => value > threshold).length;
  }

  Map<String, Object> report(String name) {
    if (_values.isEmpty) {
      return <String, Object>{
        '${name}_avg_us': 0,
        '${name}_p50_us': 0,
        '${name}_p95_us': 0,
        '${name}_p99_us': 0,
        '${name}_max_us': 0,
      };
    }
    final sorted = List<int>.of(_values)..sort();
    return <String, Object>{
      '${name}_avg_us': (_total / _values.length).round(),
      '${name}_p50_us': _percentile(sorted, 50),
      '${name}_p95_us': _percentile(sorted, 95),
      '${name}_p99_us': _percentile(sorted, 99),
      '${name}_max_us': _max,
    };
  }

  void clear() {
    _values.clear();
    _total = 0;
    _max = 0;
  }

  static int _percentile(List<int> sorted, int percentile) {
    final rank = (sorted.length * percentile + 99) ~/ 100 - 1;
    return sorted[rank];
  }
}
