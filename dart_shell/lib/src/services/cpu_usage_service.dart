import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

final cpuUsageServiceProvider = Provider<CpuUsageService>((ref) {
  return CpuUsageService();
});

/// One reading of the aggregate `cpu` line in `/proc/stat`, in jiffies.
@immutable
class CpuSample {
  const CpuSample({required this.busy, required this.total, this.temperatureC});

  final int busy;
  final int total;
  final double? temperatureC;

  /// CPU load between two samples as a 0-1 fraction, or null when the
  /// counters did not advance (or wrapped) between reads.
  static double? usageBetween(CpuSample previous, CpuSample next) {
    final total = next.total - previous.total;
    final busy = next.busy - previous.busy;
    if (total <= 0 || busy < 0) {
      return null;
    }
    return (busy / total).clamp(0.0, 1.0);
  }
}

/// Reads aggregate CPU time from `/proc/stat`, following the shell's
/// direct-sysfs pattern: best effort, no processes, null on a dev box where
/// the file is unreadable.
class CpuUsageService {
  CpuUsageService({
    this._statPath = '/proc/stat',
    String hwmonRoot = '/sys/class/hwmon',
    String thermalRoot = '/sys/class/thermal',
  }) : _temperature = CpuTemperatureReader(
         hwmonRoot: hwmonRoot,
         thermalRoot: thermalRoot,
       );

  final String _statPath;
  final CpuTemperatureReader _temperature;

  Future<CpuSample?> read() async {
    try {
      final content = await File(_statPath).readAsString();
      final sample = parseProcStat(content);
      if (sample == null) {
        return null;
      }
      return CpuSample(
        busy: sample.busy,
        total: sample.total,
        temperatureC: await _temperature.read(),
      );
    } on FileSystemException {
      return null;
    }
  }
}

/// Finds one package/CPU sensor once, then reads only its tiny sysfs value.
/// This deliberately avoids process-based collectors such as `sensors`.
class CpuTemperatureReader {
  CpuTemperatureReader({
    this._hwmonRoot = '/sys/class/hwmon',
    this._thermalRoot = '/sys/class/thermal',
  });

  final String _hwmonRoot;
  final String _thermalRoot;
  File? _sensor;
  bool _discovered = false;

  Future<double?> read() async {
    if (!_discovered) {
      _sensor = await _discover();
      _discovered = true;
    }
    final sensor = _sensor;
    if (sensor == null) {
      return null;
    }
    try {
      return parseLinuxTemperatureC(await sensor.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  Future<File?> _discover() async {
    final hwmon = await _discoverHwmonSensor();
    return hwmon ?? _discoverThermalZone();
  }

  Future<File?> _discoverHwmonSensor() async {
    final entries = await _directoryEntries(_hwmonRoot);
    for (final entry in entries) {
      final name = await _readTrimmed(p.join(entry.path, 'name'));
      if (name == null || !_cpuHwmonNames.contains(name.toLowerCase())) {
        continue;
      }
      final sensor = await _bestTemperatureInput(
        entry.path,
        scoreLabel: _cpuTemperatureLabelScore,
      );
      if (sensor != null) {
        return sensor;
      }
    }
    return null;
  }

  Future<File?> _discoverThermalZone() async {
    File? best;
    var bestScore = -1;
    for (final entry in await _directoryEntries(_thermalRoot)) {
      final type = await _readTrimmed(p.join(entry.path, 'type'));
      final score = _cpuThermalZoneScore(type ?? '');
      final sensor = File(p.join(entry.path, 'temp'));
      if (score > bestScore && sensor.existsSync()) {
        best = sensor;
        bestScore = score;
      }
    }
    return best;
  }
}

const Set<String> _cpuHwmonNames = <String>{
  'coretemp',
  'k10temp',
  'zenpower',
  'cpu_thermal',
  'cpu-thermal',
};

int _cpuTemperatureLabelScore(String label) {
  final normalized = label.toLowerCase();
  if (normalized.startsWith('package id')) {
    return 100;
  }
  if (normalized == 'tctl') {
    return 90;
  }
  if (normalized == 'tdie') {
    return 80;
  }
  if (normalized.contains('cpu')) {
    return 70;
  }
  return 0;
}

int _cpuThermalZoneScore(String type) {
  final normalized = type.toLowerCase();
  if (normalized == 'x86_pkg_temp') {
    return 100;
  }
  if (normalized.contains('cpu')) {
    return 80;
  }
  if (normalized.contains('package')) {
    return 70;
  }
  return -1;
}

Future<List<FileSystemEntity>> _directoryEntries(String path) async {
  try {
    final entries = await Directory(path).list(followLinks: false).toList();
    entries.sort((left, right) => left.path.compareTo(right.path));
    return entries;
  } on FileSystemException {
    return const <FileSystemEntity>[];
  }
}

Future<File?> _bestTemperatureInput(
  String directory, {
  required int Function(String label) scoreLabel,
}) async {
  final inputs = (await _directoryEntries(directory))
      .where((entry) => _temperatureInput.hasMatch(p.basename(entry.path)))
      .toList(growable: false);
  File? best;
  var bestScore = -1;
  for (final input in inputs) {
    final labelPath = input.path.replaceFirst(RegExp(r'_input$'), '_label');
    final label = await _readTrimmed(labelPath) ?? '';
    final score = scoreLabel(label);
    if (score > bestScore) {
      best = File(input.path);
      bestScore = score;
    }
  }
  return best;
}

final RegExp _temperatureInput = RegExp(r'^temp\d+_input$');

Future<String?> _readTrimmed(String path) async {
  try {
    return (await File(path).readAsString()).trim();
  } on FileSystemException {
    return null;
  }
}

/// Linux hwmon and thermal-zone values are normally millidegrees Celsius.
/// Plain degrees are accepted for test doubles and unusual drivers.
double? parseLinuxTemperatureC(String content) {
  final raw = double.tryParse(content.trim());
  if (raw == null || !raw.isFinite) {
    return null;
  }
  final temperature = raw.abs() >= 1000.0 ? raw / 1000.0 : raw;
  if (temperature < -100.0 || temperature > 250.0) {
    return null;
  }
  return temperature;
}

/// Parses the aggregate `cpu` line. Fields are user, nice, system, idle,
/// iowait, irq, softirq, steal; idle and iowait count as not busy. Guest
/// fields are excluded because user time already contains them.
@visibleForTesting
CpuSample? parseProcStat(String content) {
  for (final line in content.split('\n')) {
    if (!line.startsWith('cpu ')) {
      continue;
    }
    final fields = line
        .split(' ')
        .where((field) => field.isNotEmpty)
        .skip(1)
        .map(int.tryParse)
        .toList(growable: false);
    if (fields.length < 8 || fields.any((field) => field == null)) {
      return null;
    }
    final jiffies = fields.take(8).cast<int>().toList(growable: false);
    final total = jiffies.fold<int>(0, (sum, value) => sum + value);
    final idle = jiffies[3] + jiffies[4];
    return CpuSample(busy: total - idle, total: total);
  }
  return null;
}
