import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

class HomeBatteryDischargeSeries {
  factory HomeBatteryDischargeSeries({
    required List<HomeBatteryDischargePoint> points,
  }) {
    final bounded = _boundedPoints(points);
    return HomeBatteryDischargeSeries._(
      points: bounded,
      graph: HomeBatteryDischargeGraphViewModel.fromPoints(bounded),
      averageDrawMa60: _averageDrawMa(
        bounded,
        window: const Duration(seconds: 60),
        dischargingOnly: false,
      ),
    );
  }

  const HomeBatteryDischargeSeries._({
    required this.points,
    required this.graph,
    required this.averageDrawMa60,
  });

  static final empty = HomeBatteryDischargeSeries(points: const []);
  static const int _maxReadBytes = 128 * 1024;
  static const int _maxPoints = 600;

  static Future<HomeBatteryDischargeSeries> readDefault() {
    return HomeBatteryDischargeSeries.read(
      File('/run/denia-powerd/battery_discharge.tsv'),
    );
  }

  static Future<HomeBatteryDischargeSeries> read(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final length = await handle.length();
      final start = math.max(0, length - _maxReadBytes).toInt();
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      var text = utf8.decode(bytes, allowMalformed: true);
      if (start > 0) {
        final firstLineEnd = text.indexOf('\n');
        text = firstLineEnd < 0 ? '' : text.substring(firstLineEnd + 1);
      }
      return HomeBatteryDischargeSeries.parse(text);
    } on Object {
      return empty;
    } finally {
      await handle?.close();
    }
  }

  factory HomeBatteryDischargeSeries.parse(String text) {
    return HomeBatteryDischargeSeries(points: _parseLines(text.split('\n')));
  }

  final List<HomeBatteryDischargePoint> points;
  final HomeBatteryDischargeGraphViewModel graph;
  final int? averageDrawMa60;

  HomeBatteryDischargePoint? get latest {
    return points.isEmpty ? null : points.last;
  }

  Iterable<HomeBatteryDischargePoint> graphPoints({int limit = 180}) sync* {
    final start = points.length > limit ? points.length - limit : 0;
    for (var index = start; index < points.length; index += 1) {
      final point = points[index];
      if (point.drawMa != null) {
        yield point;
      }
    }
  }

  int? averageDrawMa({
    Duration window = const Duration(seconds: 60),
    bool dischargingOnly = false,
  }) {
    if (window == const Duration(seconds: 60) && !dischargingOnly) {
      return averageDrawMa60;
    }
    return _averageDrawMa(
      points,
      window: window,
      dischargingOnly: dischargingOnly,
    );
  }
}

@immutable
class HomeBatteryDischargeGraphViewModel {
  factory HomeBatteryDischargeGraphViewModel.fromPoints(
    List<HomeBatteryDischargePoint> source, {
    int limit = 180,
  }) {
    final start = source.length > limit ? source.length - limit : 0;
    final points = <HomeBatteryDischargePoint>[];
    var minIndex = -1;
    var maxIndex = -1;
    var sum = 0;
    for (var index = start; index < source.length; index += 1) {
      final point = source[index];
      final drawMa = point.drawMa;
      if (drawMa == null) {
        continue;
      }
      final graphIndex = points.length;
      points.add(point);
      sum += drawMa;
      if (minIndex < 0 || drawMa < points[minIndex].drawMa!) {
        minIndex = graphIndex;
      }
      if (maxIndex < 0 || drawMa > points[maxIndex].drawMa!) {
        maxIndex = graphIndex;
      }
    }
    final immutablePoints = List<HomeBatteryDischargePoint>.unmodifiable(
      points,
    );
    final maximum = maxIndex < 0 ? 50 : immutablePoints[maxIndex].drawMa!;
    return HomeBatteryDischargeGraphViewModel._(
      points: immutablePoints,
      minIndex: minIndex,
      maxIndex: maxIndex,
      latestIndex: immutablePoints.isEmpty ? -1 : immutablePoints.length - 1,
      averageDrawMa: immutablePoints.isEmpty
          ? null
          : sum ~/ immutablePoints.length,
      scaleMaxMa: maximum.clamp(50, 2000).toDouble(),
    );
  }

  const HomeBatteryDischargeGraphViewModel._({
    required this.points,
    required this.minIndex,
    required this.maxIndex,
    required this.latestIndex,
    required this.averageDrawMa,
    required this.scaleMaxMa,
  });

  final List<HomeBatteryDischargePoint> points;
  final int minIndex;
  final int maxIndex;
  final int latestIndex;
  final int? averageDrawMa;
  final double scaleMaxMa;

  HomeBatteryDischargePoint? get minPoint =>
      minIndex < 0 ? null : points[minIndex];

  HomeBatteryDischargePoint? get maxPoint =>
      maxIndex < 0 ? null : points[maxIndex];

  HomeBatteryDischargePoint? get latestPoint =>
      latestIndex < 0 ? null : points[latestIndex];

  bool get hasValues => latestIndex >= 0;
}

/// Incrementally follows powerd's append-only history without reparsing it.
///
/// Filesystem events are authoritative. The slow watchdog only recovers a
/// dropped watch or missed rotation; unchanged files cost one metadata read
/// and never republish the series.
class HomeBatteryDischargeTailReader {
  HomeBatteryDischargeTailReader({
    File? file,
    this.eventDebounce = const Duration(milliseconds: 120),
    this.recoveryInterval = const Duration(minutes: 1),
  }) : file = file ?? File('/run/denia-powerd/battery_discharge.tsv'),
       _current = HomeBatteryDischargeSeries.empty {
    _controller.onListen = () => unawaited(_start());
  }

  final File file;
  final Duration eventDebounce;
  final Duration recoveryInterval;

  final StreamController<HomeBatteryDischargeSeries> _controller =
      StreamController<HomeBatteryDischargeSeries>();
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _eventTimer;
  Timer? _recoveryTimer;
  HomeBatteryDischargeSeries _current;
  List<HomeBatteryDischargePoint> _points = <HomeBatteryDischargePoint>[];
  String _remainder = '';
  int _offset = 0;
  bool _started = false;
  bool _disposed = false;
  bool _watchSetupPending = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _resetRequested = false;
  bool _forcedEmissionRequested = false;

  Stream<HomeBatteryDischargeSeries> get snapshots => _controller.stream;

  @visibleForTesting
  bool get debugHasActiveWatch => _watchSubscription != null;

  Future<void> _start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    await _ensureWatch();
    await _refresh(reset: true, forceEmission: true);
    if (_disposed) {
      return;
    }
    _recoveryTimer = Timer.periodic(recoveryInterval, (_) {
      unawaited(_ensureWatch());
      unawaited(_refresh());
    });
  }

  Future<void> _ensureWatch() async {
    if (_disposed || _watchSubscription != null || _watchSetupPending) {
      return;
    }
    _watchSetupPending = true;
    try {
      final directory = file.parent;
      if (!await directory.exists()) {
        return;
      }
      if (_disposed || _watchSubscription != null) {
        return;
      }
      _watchSubscription = directory.watch().listen(
        _handleFileEvent,
        onError: (_) => _dropWatch(),
        onDone: _dropWatch,
        cancelOnError: true,
      );
    } on FileSystemException {
      // The recovery watchdog retries when powerd creates its runtime folder.
    } finally {
      _watchSetupPending = false;
    }
  }

  void _dropWatch() {
    final subscription = _watchSubscription;
    _watchSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }

  void _handleFileEvent(FileSystemEvent event) {
    if (_disposed || event.path != file.path) {
      return;
    }
    final reset =
        event is FileSystemCreateEvent ||
        event is FileSystemDeleteEvent ||
        event is FileSystemMoveEvent;
    _eventTimer?.cancel();
    _eventTimer = Timer(eventDebounce, () => unawaited(_refresh(reset: reset)));
  }

  Future<void> _refresh({
    bool reset = false,
    bool forceEmission = false,
  }) async {
    if (_disposed) {
      return;
    }
    _resetRequested = _resetRequested || reset;
    _forcedEmissionRequested = _forcedEmissionRequested || forceEmission;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        final shouldReset = _resetRequested;
        final shouldForceEmission = _forcedEmissionRequested;
        _resetRequested = false;
        _forcedEmissionRequested = false;
        final changed = await _readAppended(reset: shouldReset);
        if ((changed || shouldForceEmission) &&
            !_disposed &&
            !_controller.isClosed) {
          _controller.add(_current);
        }
      } while (_refreshAgain && !_disposed);
    } finally {
      _refreshing = false;
    }
  }

  Future<bool> _readAppended({required bool reset}) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final length = await handle.length();
      final mustReset = reset || length < _offset;
      final start = mustReset
          ? math
                .max(0, length - HomeBatteryDischargeSeries._maxReadBytes)
                .toInt()
          : _offset;
      if (!mustReset && length == _offset) {
        return false;
      }
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      var appended = utf8.decode(bytes, allowMalformed: true);
      if (mustReset) {
        _points = <HomeBatteryDischargePoint>[];
        _remainder = '';
        if (start > 0) {
          final firstLineEnd = appended.indexOf('\n');
          appended = firstLineEnd < 0
              ? ''
              : appended.substring(firstLineEnd + 1);
        }
      }
      _offset = length;
      final combined = '$_remainder$appended';
      final finalLineEnd = combined.lastIndexOf('\n');
      if (finalLineEnd < 0) {
        _remainder = combined;
        if (mustReset && _current.points.isNotEmpty) {
          _current = HomeBatteryDischargeSeries.empty;
          return true;
        }
        return false;
      }
      final complete = combined.substring(0, finalLineEnd);
      _remainder = combined.substring(finalLineEnd + 1);
      final additions = _parseLines(complete.split('\n'));
      if (additions.isEmpty) {
        if (mustReset && _current.points.isNotEmpty) {
          _current = HomeBatteryDischargeSeries.empty;
          return true;
        }
        return false;
      }
      _points.addAll(additions);
      _points = _boundedPoints(_points).toList(growable: true);
      _current = HomeBatteryDischargeSeries(points: _points);
      return true;
    } on FileSystemException {
      if (reset && _current.points.isNotEmpty) {
        _offset = 0;
        _remainder = '';
        _points = <HomeBatteryDischargePoint>[];
        _current = HomeBatteryDischargeSeries.empty;
        return true;
      }
      return false;
    } finally {
      await handle?.close();
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _eventTimer?.cancel();
    _recoveryTimer?.cancel();
    await _watchSubscription?.cancel();
    _watchSubscription = null;
    await _controller.close();
  }
}

class HomeBatteryDischargePoint {
  const HomeBatteryDischargePoint({
    required this.wallMs,
    required this.state,
    required this.capacity,
    required this.currentMa,
    required this.voltageMv,
    required this.powerMw,
  });

  final int wallMs;
  final String state;
  final int? capacity;
  final int? currentMa;
  final int? voltageMv;
  final int? powerMw;

  int? get drawMa {
    final value = currentMa;
    return value?.abs();
  }

  double? get powerW {
    final value = powerMw;
    return value == null ? null : value / 1000;
  }

  double? get voltageV {
    final value = voltageMv;
    return value == null ? null : value / 1000;
  }
}

List<HomeBatteryDischargePoint> _boundedPoints(
  List<HomeBatteryDischargePoint> points,
) {
  final recent = points.length <= HomeBatteryDischargeSeries._maxPoints
      ? points
      : points.sublist(points.length - HomeBatteryDischargeSeries._maxPoints);
  return List<HomeBatteryDischargePoint>.unmodifiable(recent);
}

List<HomeBatteryDischargePoint> _parseLines(Iterable<String> lines) {
  final points = <HomeBatteryDischargePoint>[];
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('ts_ms\t')) {
      continue;
    }

    final fields = line.split('\t');
    if (fields.length < 7) {
      continue;
    }

    final tsMs = int.tryParse(fields[0]);
    if (tsMs == null) {
      continue;
    }

    points.add(
      HomeBatteryDischargePoint(
        wallMs: tsMs,
        state: fields[2].toLowerCase(),
        capacity: _parseOptionalInt(fields[3]),
        currentMa: _parseOptionalInt(fields[4]),
        voltageMv: _parseOptionalInt(fields[5]),
        powerMw: _parseOptionalInt(fields[6]),
      ),
    );
  }
  return points;
}

int? _averageDrawMa(
  List<HomeBatteryDischargePoint> points, {
  required Duration window,
  required bool dischargingOnly,
}) {
  final newest = points.isEmpty ? null : points.last.wallMs;
  if (newest == null) {
    return null;
  }

  final start = newest - window.inMilliseconds;
  var sum = 0;
  var count = 0;
  for (final point in points.reversed) {
    if (point.wallMs < start) {
      break;
    }
    if (dischargingOnly && point.state != 'discharging') {
      continue;
    }
    final drawMa = point.drawMa;
    if (drawMa == null) {
      continue;
    }
    sum += drawMa;
    count += 1;
  }
  return count == 0 ? null : sum ~/ count;
}

int? _parseOptionalInt(String value) {
  if (value == 'unknown' || value.isEmpty) {
    return null;
  }
  return int.tryParse(value);
}
