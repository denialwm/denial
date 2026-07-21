import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'cpu_usage_service.dart' show parseLinuxTemperatureC;

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

  Future<List<GpuSample>> read() async {
    final sysfsGpus = _sysfsGpus ??= await _discoverSysfs();
    final samples = <GpuSample>[];
    for (final gpu in sysfsGpus) {
      final sample = await gpu.read();
      if (sample != null) {
        samples.add(sample);
      }
    }
    samples.addAll(_nvml.read());
    return disambiguateGpuLabels(samples);
  }

  Future<List<_SysfsGpu>> _discoverSysfs() async {
    final gpus = <_SysfsGpu>[];
    try {
      await for (final entry in Directory(_drmRoot).list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (!_cardName.hasMatch(name)) {
          continue;
        }
        final devicePath = p.join(entry.path, 'device');
        final busyFile = File(p.join(devicePath, 'gpu_busy_percent'));
        if (!busyFile.existsSync()) {
          continue;
        }
        gpus.add(
          _SysfsGpu(
            id: name,
            label: await _vendorLabel(p.join(devicePath, 'vendor')),
            busyFile: busyFile,
            temperatureFile: await _discoverGpuTemperatureFile(
              p.join(devicePath, 'hwmon'),
            ),
          ),
        );
      }
    } on FileSystemException {
      return const <_SysfsGpu>[];
    }
    gpus.sort((a, b) => a.id.compareTo(b.id));
    return gpus;
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

/// Minimal NVML binding for utilization and optional temperature. The library
/// is opened on first use; any failure marks NVML permanently unavailable so
/// a box without the proprietary driver pays a single failed dlopen.
class NvmlReader {
  NvmlReader();

  bool _ready = false;
  bool _unavailable = false;
  List<ffi.Pointer<ffi.Void>> _devices = const <ffi.Pointer<ffi.Void>>[];
  late final int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_NvmlUtilization>)
  _getUtilization;
  int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint32>)?
  _getTemperature;

  List<GpuSample> read() {
    if (_unavailable || (!_ready && !_initialize())) {
      return const <GpuSample>[];
    }
    final utilization = pkg_ffi.calloc<_NvmlUtilization>();
    final temperature = pkg_ffi.calloc<ffi.Uint32>();
    try {
      final samples = <GpuSample>[];
      for (var index = 0; index < _devices.length; index += 1) {
        final device = _devices[index];
        if (_getUtilization(device, utilization) != 0) {
          continue;
        }
        double? temperatureC;
        final getTemperature = _getTemperature;
        if (getTemperature != null &&
            getTemperature(device, 0, temperature) == 0) {
          temperatureC = temperature.value.toDouble();
        }
        samples.add(
          GpuSample(
            id: 'nvml$index',
            label: 'NV',
            usage: (utilization.ref.gpu / 100.0).clamp(0.0, 1.0),
            temperatureC: temperatureC,
          ),
        );
      }
      return samples;
    } finally {
      pkg_ffi.calloc.free(utilization);
      pkg_ffi.calloc.free(temperature);
    }
  }

  bool _initialize() {
    try {
      final library = ffi.DynamicLibrary.open('libnvidia-ml.so.1');
      final init = library.lookupFunction<ffi.Int32 Function(), int Function()>(
        'nvmlInit_v2',
      );
      if (init() != 0) {
        _unavailable = true;
        return false;
      }
      final getCount = library
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Uint32>),
            int Function(ffi.Pointer<ffi.Uint32>)
          >('nvmlDeviceGetCount_v2');
      final getHandle = library
          .lookupFunction<
            ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Pointer<ffi.Void>>),
            int Function(int, ffi.Pointer<ffi.Pointer<ffi.Void>>)
          >('nvmlDeviceGetHandleByIndex_v2');
      _getUtilization = library
          .lookupFunction<
            ffi.Int32 Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<_NvmlUtilization>,
            ),
            int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_NvmlUtilization>)
          >('nvmlDeviceGetUtilizationRates');
      try {
        _getTemperature = library
            .lookupFunction<
              ffi.Int32 Function(
                ffi.Pointer<ffi.Void>,
                ffi.Int32,
                ffi.Pointer<ffi.Uint32>,
              ),
              int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint32>)
            >('nvmlDeviceGetTemperature');
      } on Object {
        _getTemperature = null;
      }

      final count = pkg_ffi.calloc<ffi.Uint32>();
      final handle = pkg_ffi.calloc<ffi.Pointer<ffi.Void>>();
      try {
        if (getCount(count) != 0) {
          _unavailable = true;
          return false;
        }
        _devices = <ffi.Pointer<ffi.Void>>[
          for (var index = 0; index < count.value; index += 1)
            if (getHandle(index, handle) == 0) handle.value,
        ];
      } finally {
        pkg_ffi.calloc.free(count);
        pkg_ffi.calloc.free(handle);
      }
      _ready = true;
      return true;
    } on Object {
      _unavailable = true;
      return false;
    }
  }
}

final class _NvmlUtilization extends ffi.Struct {
  @ffi.Uint32()
  external int gpu;

  @ffi.Uint32()
  external int memory;
}
