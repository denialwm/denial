import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Opt-in counters for the Dart-side stages of desktop window rendering.
///
/// Enable these counters together with the native damage and raster-cache
/// audit by starting Denial with `DENIA_RENDER_AUDIT=1`. The timer does not
/// schedule Flutter frames; it only reports work that happened independently.
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

  static void install({required bool enabled}) {
    if (_enabled || !enabled) {
      return;
    }
    _enabled = true;
    _clock.start();
    Timer.periodic(
      const Duration(seconds: 1),
      (_) => _report(),
    );
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
    _shadowPaints.update(
      windowId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  static void recordBorderPaint(int windowId, Size size) {
    if (!_enabled) {
      return;
    }
    _knownWindows.add(windowId);
    _lastPaintSizes[windowId] = size;
    _borderPaints.update(
      windowId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
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
