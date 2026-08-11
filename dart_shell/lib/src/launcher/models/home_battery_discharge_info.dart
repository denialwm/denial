import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class HomeBatteryDischargeSeries {
  const HomeBatteryDischargeSeries({required this.points});

  static const empty = HomeBatteryDischargeSeries(points: []);
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
    final points = <HomeBatteryDischargePoint>[];
    for (final rawLine in text.split('\n')) {
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

    final recent = points.length <= _maxPoints
        ? points
        : points.sublist(points.length - _maxPoints);
    return HomeBatteryDischargeSeries(points: List.unmodifiable(recent));
  }

  final List<HomeBatteryDischargePoint> points;

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
    final newest = latest?.wallMs;
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

int? _parseOptionalInt(String value) {
  if (value == 'unknown' || value.isEmpty) {
    return null;
  }
  return int.tryParse(value);
}
