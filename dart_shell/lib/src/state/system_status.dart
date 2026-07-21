import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final batteryProvider = NotifierProvider<BatteryController, BatteryStatus>(
  BatteryController.new,
  isAutoDispose: true,
);

final powerStatusProvider =
    NotifierProvider<PowerStatusController, ShellPowerStatus>(
      PowerStatusController.new,
      isAutoDispose: true,
    );

/// Aggregate CPU load plus a short history window for the bar sparkline.
final cpuUsageProvider = NotifierProvider<CpuUsageController, LoadSeries>(
  CpuUsageController.new,
  isAutoDispose: true,
);

/// Per-GPU load series for every autodetected GPU, in stable order.
final gpuUsageProvider = NotifierProvider<GpuUsageController, List<GpuLoad>>(
  GpuUsageController.new,
  isAutoDispose: true,
);

mixin _PeriodicRefresh<StateT> on Notifier<StateT> {
  int _refreshGeneration = 0;
  bool _refreshing = false;

  void startPeriodicRefresh(
    Duration interval,
    Future<void> Function(int generation) refresh,
  ) {
    final generation = ++_refreshGeneration;
    _refreshing = false;

    Future<void> run() async {
      if (!isRefreshActive(generation) || _refreshing) {
        return;
      }
      _refreshing = true;
      try {
        await refresh(generation);
      } finally {
        if (generation == _refreshGeneration) {
          _refreshing = false;
        }
      }
    }

    scheduleMicrotask(() => unawaited(run()));
    final timer = Timer.periodic(interval, (_) => unawaited(run()));
    ref.onDispose(() {
      timer.cancel();
      if (generation == _refreshGeneration) {
        _refreshGeneration++;
        _refreshing = false;
      }
    });
  }

  bool isRefreshActive(int generation) =>
      ref.mounted && generation == _refreshGeneration;
}

/// Polls the battery on a fixed interval.
class BatteryController extends Notifier<BatteryStatus>
    with _PeriodicRefresh<BatteryStatus> {
  @override
  BatteryStatus build() {
    _service = ref.watch(batteryServiceProvider);
    startPeriodicRefresh(_interval, _refresh);
    return BatteryStatus.unknown;
  }

  static const Duration _interval = Duration(seconds: 15);

  late BatteryService _service;

  Future<void> _refresh(int generation) async {
    final status = await _service.read();
    if (isRefreshActive(generation) && status != state) {
      state = status;
    }
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
class CpuUsageController extends Notifier<LoadSeries>
    with _PeriodicRefresh<LoadSeries> {
  @override
  LoadSeries build() {
    _service = ref.watch(cpuUsageServiceProvider);
    _previous = null;
    startPeriodicRefresh(_interval, _refresh);
    return LoadSeries.empty;
  }

  static const Duration _interval = Duration(seconds: 2);

  late CpuUsageService _service;
  CpuSample? _previous;

  Future<void> _refresh(int generation) async {
    final sample = await _service.read();
    if (!isRefreshActive(generation)) {
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
  }
}

/// Polls every autodetected GPU on a fixed interval and appends each reading
/// to that GPU's series. GPUs whose telemetry disappears drop off the list.
class GpuUsageController extends Notifier<List<GpuLoad>>
    with _PeriodicRefresh<List<GpuLoad>> {
  @override
  List<GpuLoad> build() {
    _service = ref.watch(gpuUsageServiceProvider);
    startPeriodicRefresh(_interval, _refresh);
    return const <GpuLoad>[];
  }

  static const Duration _interval = Duration(seconds: 2);

  late GpuUsageService _service;

  Future<void> _refresh(int generation) async {
    final samples = await _service.read();
    if (!isRefreshActive(generation) || (samples.isEmpty && state.isEmpty)) {
      return;
    }
    final previous = <String, GpuLoad>{for (final load in state) load.id: load};
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
  }
}

class PowerStatusController extends Notifier<ShellPowerStatus>
    with _PeriodicRefresh<ShellPowerStatus> {
  @override
  ShellPowerStatus build() {
    _service = ref.watch(powerStatusServiceProvider);
    startPeriodicRefresh(_interval, _refresh);
    return ShellPowerStatus.unknown;
  }

  static const Duration _interval = Duration(seconds: 2);

  late PowerStatusService _service;

  Future<void> _refresh(int generation) async {
    final status = await _service.read();
    if (isRefreshActive(generation) && status != state) {
      state = status;
    }
  }
}
