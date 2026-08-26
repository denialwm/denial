import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'cpu_usage_service.dart' show parseLinuxTemperatureC;
import 'shell_worker.dart';

final gpuUsageServiceProvider = Provider<GpuUsageService>((ref) {
  return GpuUsageService();
});

/// One GPU utilization reading as a 0-1 fraction.
@immutable
class GpuSample {
  const GpuSample({
    required this.id,
    required this.label,
    required this.usage,
    this.temperatureC,
  });

  /// Stable identity across reads (`card2`, `nvml0`).
  final String id;

  /// Compact vendor tag for the bar pill (`AMD`, `NV`, `INT`, `GPU`).
  final String label;

  final double usage;
  final double? temperatureC;
}

/// Autodetects every GPU whose utilization is readable without spawning
/// processes, following the shell's direct-sysfs pattern: amdgpu publishes
/// `gpu_busy_percent` under /sys/class/drm, and NVIDIA's proprietary driver
/// exposes NVML, bound lazily over dart:ffi. GPUs offering neither (i915,
/// nouveau) simply do not appear; every failure collapses to "no reading".
class GpuUsageService {
  GpuUsageService({this._drmRoot = '/sys/class/drm', NvmlReader? nvml})
    : _nvml = nvml ?? NvmlReader();

  final String _drmRoot;
  final NvmlReader _nvml;
  List<_SysfsGpu>? _sysfsGpus;
  List<File>? _nvidiaRuntimeStatusFiles;

  Future<List<GpuSample>> read() async {
    final sysfsGpus = _sysfsGpus ??= await _discoverSysfs();
    final samples = <GpuSample>[];
    for (final gpu in sysfsGpus) {
      final sample = await gpu.read();
      if (sample != null) {
        samples.add(sample);
      }
    }
    if (await _canReadNvidiaWithoutWake()) {
      samples.addAll(await _nvml.read());
    } else {
      final sleepingNvidiaGpus = _nvidiaRuntimeStatusFiles!.length;
      for (var index = 0; index < sleepingNvidiaGpus; index += 1) {
        samples.add(
          GpuSample(id: 'nvml$index', label: 'NV', usage: 0.0),
        );
      }
    }
    return disambiguateGpuLabels(samples);
  }

  Future<List<_SysfsGpu>> _discoverSysfs() async {
    final gpus = <_SysfsGpu>[];
    final nvidiaRuntimeStatusFiles = <File>[];
    try {
      await for (final entry in Directory(_drmRoot).list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (!_cardName.hasMatch(name)) {
          continue;
        }
        final devicePath = p.join(entry.path, 'device');
        final label = await _vendorLabel(p.join(devicePath, 'vendor'));
        if (label == 'NV') {
          final runtimeStatus = File(
            p.join(devicePath, 'power', 'runtime_status'),
          );
          if (runtimeStatus.existsSync()) {
            nvidiaRuntimeStatusFiles.add(runtimeStatus);
          }
        }
        final busyFile = File(p.join(devicePath, 'gpu_busy_percent'));
        if (!busyFile.existsSync()) {
          continue;
        }
        gpus.add(
          _SysfsGpu(
            id: name,
            label: label,
            busyFile: busyFile,
            temperatureFile: await _discoverGpuTemperatureFile(
              p.join(devicePath, 'hwmon'),
            ),
          ),
        );
      }
    } on FileSystemException {
      _nvidiaRuntimeStatusFiles = const <File>[];
      return const <_SysfsGpu>[];
    }
    _nvidiaRuntimeStatusFiles = nvidiaRuntimeStatusFiles;
    gpus.sort((a, b) => a.id.compareTo(b.id));
    return gpus;
  }

  Future<bool> _canReadNvidiaWithoutWake() async {
    final statusFiles = _nvidiaRuntimeStatusFiles;
    if (statusFiles == null || statusFiles.isEmpty) {
      // Desktop NVIDIA systems may not expose runtime PM through DRM. Keep
      // NVML available there because querying an always-on GPU cannot wake it.
      return true;
    }
    var suspended = false;
    for (final statusFile in statusFiles) {
      try {
        final status = (await statusFile.readAsString()).trim();
        if (status == 'active' || status == 'unsupported') {
          continue;
        }
        if (status == 'suspended' ||
            status == 'suspending' ||
            status == 'resuming') {
          suspended = true;
        } else {
          // Unknown kernels remain compatible instead of silently hiding a
          // GPU which is already powered.
          continue;
        }
      } on FileSystemException {
        continue;
      }
    }
    // NVML utilization and temperature queries power on a runtime-suspended
    // dGPU. Leave hybrid graphics asleep until another workload activates it.
    return !suspended;
  }

  static final RegExp _cardName = RegExp(r'^card\d+$');

  static Future<String> _vendorLabel(String vendorPath) async {
    try {
      final vendor = (await File(vendorPath).readAsString()).trim();
      return switch (vendor) {
        '0x1002' => 'AMD',
        '0x10de' => 'NV',
        '0x8086' => 'INT',
        _ => 'GPU',
      };
    } on FileSystemException {
      return 'GPU';
    }
  }
}

/// Suffixes duplicated vendor tags with a stable index (`NV0`, `NV1`) so two
/// identical cards keep distinguishable pills; unique tags stay untouched.
@visibleForTesting
List<GpuSample> disambiguateGpuLabels(List<GpuSample> samples) {
  final counts = <String, int>{};
  for (final sample in samples) {
    counts[sample.label] = (counts[sample.label] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return <GpuSample>[
    for (final sample in samples)
      if (counts[sample.label]! > 1)
        GpuSample(
          id: sample.id,
          label:
              '${sample.label}${seen[sample.label] = (seen[sample.label] ?? -1) + 1}',
          usage: sample.usage,
          temperatureC: sample.temperatureC,
        )
      else
        sample,
  ];
}

/// Parses one `gpu_busy_percent` read (an integer percentage) into a 0-1
/// fraction, or null for malformed contents.
@visibleForTesting
double? parseGpuBusyPercent(String content) {
  final percent = int.tryParse(content.trim());
  if (percent == null) {
    return null;
  }
  return (percent / 100.0).clamp(0.0, 1.0);
}

class _SysfsGpu {
  const _SysfsGpu({
    required this.id,
    required this.label,
    required this.busyFile,
    required this.temperatureFile,
  });

  final String id;
  final String label;
  final File busyFile;
  final File? temperatureFile;

  Future<GpuSample?> read() async {
    try {
      final usage = parseGpuBusyPercent(await busyFile.readAsString());
      if (usage == null) {
        return null;
      }
      double? temperatureC;
      final temperature = temperatureFile;
      if (temperature != null) {
        try {
          temperatureC = parseLinuxTemperatureC(
            await temperature.readAsString(),
          );
        } on FileSystemException {
          // Utilization remains useful when an optional sensor disappears.
        }
      }
      return GpuSample(
        id: id,
        label: label,
        usage: usage,
        temperatureC: temperatureC,
      );
    } on FileSystemException {
      return null;
    }
  }
}

Future<File?> _discoverGpuTemperatureFile(String hwmonRoot) async {
  try {
    final hwmons = await Directory(hwmonRoot).list(followLinks: false).toList();
    hwmons.sort((left, right) => left.path.compareTo(right.path));
    File? best;
    var bestScore = -1;
    for (final hwmon in hwmons) {
      final entries = await Directory(
        hwmon.path,
      ).list(followLinks: false).toList();
      entries.sort((left, right) => left.path.compareTo(right.path));
      for (final entry in entries) {
        if (!_temperatureInput.hasMatch(p.basename(entry.path))) {
          continue;
        }
        final labelPath = entry.path.replaceFirst(RegExp(r'_input$'), '_label');
        var label = '';
        try {
          label = (await File(labelPath).readAsString()).trim().toLowerCase();
        } on FileSystemException {
          // An unlabelled temp1_input is still a valid fallback.
        }
        final score = switch (label) {
          'edge' => 100,
          'gpu' => 90,
          'junction' => 80,
          _ => 0,
        };
        if (score > bestScore) {
          best = File(entry.path);
          bestScore = score;
        }
      }
    }
    return best;
  } on FileSystemException {
    return null;
  }
}

final RegExp _temperatureInput = RegExp(r'^temp\d+_input$');

/// Typed UI-isolate facade for NVML readings owned by [ShellWorker].
///
/// The direct FFI calls execute only on its persistent NVIDIA worker isolate.
/// A missing library or worker failure remains a best-effort empty reading.
class NvmlReader {
  NvmlReader({ShellWorker? worker}) : _worker = worker ?? ShellWorker.instance;

  final ShellWorker _worker;

  Future<List<GpuSample>> read() async {
    try {
      return <GpuSample>[
        for (final sample in await _worker.readNvidiaGpuSamples())
          GpuSample(
            id: 'nvml${sample.index}',
            label: 'NV',
            usage: sample.usage,
            temperatureC: sample.temperatureC,
          ),
      ];
    } on Object {
      return const <GpuSample>[];
    }
  }
}
