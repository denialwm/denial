import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../config/startup_environment.dart';
import '../models/battery_status.dart';
import '../models/shell_clock_info.dart';
import '../models/shell_power_status.dart';
import '../services/battery_service.dart';
import '../services/cpu_usage_service.dart';
import '../services/gpu_usage_service.dart';
import '../services/power_status_service.dart';

final clockLocaleProvider = Provider<String>((ref) {
  return ShellClockInfo.localeFromEnvironment(
    ref.watch(startupEnvironmentProvider).values,
  );
});

/// Emits immediately and then exactly at minute boundaries. Every clock in the
/// shell renders only `HH:mm`, so a per-second rebuild would be invisible work.
final clockProvider = StreamProvider<DateTime>((ref) => _minuteClock());

Stream<DateTime> _minuteClock() async* {
  while (true) {
    final now = DateTime.now();
    yield now;
    final nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute + 1,
    );
    final delay = nextMinute.difference(DateTime.now());
    await Future<void>.delayed(
      delay.isNegative ? const Duration(milliseconds: 20) : delay,
    );
  }
}

final batteryProvider = StateNotifierProvider<BatteryController, BatteryStatus>(
  (ref) {
    return BatteryController(ref.read(batteryServiceProvider));
  },
);

final powerStatusProvider =
    StateNotifierProvider.autoDispose<PowerStatusController, ShellPowerStatus>((
      ref,
    ) {
      return PowerStatusController(ref.read(powerStatusServiceProvider));
    });

/// Aggregate CPU load plus a short history window for the bar sparkline.
final cpuUsageProvider = StateNotifierProvider<CpuUsageController, LoadSeries>((
  ref,
) {
  return CpuUsageController(ref.read(cpuUsageServiceProvider));
});

/// Per-GPU load series for every autodetected GPU, in stable order.
final gpuUsageProvider =
    StateNotifierProvider<GpuUsageController, List<GpuLoad>>((ref) {
      return GpuUsageController(ref.read(gpuUsageServiceProvider));
    });

/// Polls the battery on a fixed interval.
class BatteryController extends StateNotifier<BatteryStatus> {
  BatteryController(this._service) : super(BatteryStatus.unknown) {
    unawaited(_refresh());
    _timer = Timer.periodic(_interval, (_) => unawaited(_refresh()));
  }

  static const Duration _interval = Duration(seconds: 15);

  final BatteryService _service;
  Timer? _timer;
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final status = await _service.read();
      if (mounted && status != state) {
        state = status;
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A rolling load series: the most recent 0-1 reading plus the trailing
/// window the system bar sparklines draw, oldest first.
@immutable
class LoadSeries {
  const LoadSeries({
    this.current,
    this.history = const <double>[],
    this.temperatureC,
  });

  static const LoadSeries empty = LoadSeries();

  /// Samples each sparkline keeps: 45 readings at the 2 s cadence ≈ 90 s.
  static const int capacity = 45;

  /// The newest reading as a 0-1 fraction, or null before one exists.
  final double? current;

  /// Up to [capacity] readings, oldest first; the newest equals [current].
  final List<double> history;

  /// Latest directly reported package/device temperature, when available.
  final double? temperatureC;

  LoadSeries append(double usage, {double? temperatureC}) {
    final next = <double>[...history, usage];
    if (next.length > capacity) {
      next.removeRange(0, next.length - capacity);
    }
    return LoadSeries(
      current: usage,
      history: List.unmodifiable(next),
      temperatureC: temperatureC ?? this.temperatureC,
    );
  }
}

/// One autodetected GPU with its rolling load series.
@immutable
class GpuLoad {
  const GpuLoad({
    required this.id,
    required this.label,
    this.series = LoadSeries.empty,
  });

  /// Stable identity across polls (`card2`, `nvml0`).
  final String id;

  /// Compact vendor tag shown in the pill (`AMD`, `NV`, `NV0`…).
  final String label;

  final LoadSeries series;
}

/// Samples `/proc/stat` on a fixed interval; each usable delta between the two
/// most recent samples is appended to the published [LoadSeries].
class CpuUsageController extends StateNotifier<LoadSeries> {
  CpuUsageController(this._service) : super(LoadSeries.empty) {
    unawaited(_refresh());
    _timer = Timer.periodic(_interval, (_) => unawaited(_refresh()));
  }

  /// A frozen reading that never polls, for widget tests and previews.
  @visibleForTesting
  CpuUsageController.fixed(LoadSeries load)
    : _service = CpuUsageService(),
      super(load);

  static const Duration _interval = Duration(seconds: 2);

  final CpuUsageService _service;
  Timer? _timer;
  bool _refreshing = false;
  CpuSample? _previous;

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final sample = await _service.read();
      if (!mounted) {
        return;
      }
      final previous = _previous;
      _previous = sample ?? _previous;
      if (sample == null || previous == null) {
        return;
      }
      final usage = CpuSample.usageBetween(previous, sample);
      if (usage != null) {
        state = state.append(usage, temperatureC: sample.temperatureC);
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Polls every autodetected GPU on a fixed interval and appends each reading
/// to that GPU's series. GPUs whose telemetry disappears drop off the list.
class GpuUsageController extends StateNotifier<List<GpuLoad>> {
  GpuUsageController(this._service) : super(const <GpuLoad>[]) {
    unawaited(_refresh());
    _timer = Timer.periodic(_interval, (_) => unawaited(_refresh()));
  }

  /// Frozen readings that never poll, for widget tests and previews.
  @visibleForTesting
  GpuUsageController.fixed(List<GpuLoad> loads)
    : _service = GpuUsageService(),
      super(loads);

  static const Duration _interval = Duration(seconds: 2);

  final GpuUsageService _service;
  Timer? _timer;
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final samples = await _service.read();
      if (!mounted || (samples.isEmpty && state.isEmpty)) {
        return;
      }
      final previous = <String, GpuLoad>{
        for (final load in state) load.id: load,
      };
      state = <GpuLoad>[
        for (final sample in samples)
          GpuLoad(
            id: sample.id,
            label: sample.label,
            series: (previous[sample.id]?.series ?? LoadSeries.empty).append(
              sample.usage,
              temperatureC: sample.temperatureC,
            ),
          ),
      ];
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class PowerStatusController extends StateNotifier<ShellPowerStatus> {
  PowerStatusController(this._service) : super(ShellPowerStatus.unknown) {
    unawaited(_refresh());
    _timer = Timer.periodic(_interval, (_) => unawaited(_refresh()));
  }

  static const Duration _interval = Duration(seconds: 2);

  final PowerStatusService _service;
  Timer? _timer;
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final status = await _service.read();
      if (mounted && status != state) {
        state = status;
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
