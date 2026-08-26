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

final batteryServiceProvider = Provider<BatteryService>((ref) {
  return const BatteryService();
});

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

final _systemTelemetryProvider =
    NotifierProvider<SystemTelemetryController, SystemTelemetrySnapshot>(
      SystemTelemetryController.new,
      isAutoDispose: true,
    );

final powerStatusProvider = Provider<ShellPowerStatus>(
  (ref) => ref.watch(
    _systemTelemetryProvider.select((telemetry) => telemetry.power),
  ),
  isAutoDispose: true,
);

/// Shell power state with battery capacity/state sourced exclusively from the
/// standard Linux power-supply interface. Protocol and thermal metadata remain
/// available from the optional extended status source.
final effectivePowerStatusProvider = Provider<ShellPowerStatus>((ref) {
  return ref
      .watch(powerStatusProvider)
      .withStandardBattery(ref.watch(batteryProvider));
}, isAutoDispose: true);

/// Aggregate CPU load plus a short history window for the bar sparkline.
final cpuUsageProvider = Provider<LoadSeries>(
  (ref) =>
      ref.watch(_systemTelemetryProvider.select((telemetry) => telemetry.cpu)),
  isAutoDispose: true,
);

/// Per-GPU load series for every autodetected GPU, in stable order.
final gpuUsageProvider = Provider<List<GpuLoad>>(
  (ref) =>
      ref.watch(_systemTelemetryProvider.select((telemetry) => telemetry.gpus)),
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

@immutable
class SystemTelemetrySnapshot {
  const SystemTelemetrySnapshot({
    this.cpu = LoadSeries.empty,
    this.gpus = const <GpuLoad>[],
    this.power = ShellPowerStatus.unknown,
  });

  final LoadSeries cpu;
  final List<GpuLoad> gpus;
  final ShellPowerStatus power;
}

/// Samples CPU, GPU, and extended power status on one shared cadence.
///
/// All reads start together and the immutable snapshot is published once, so
/// consumers retain fine-grained selectors without three independent timers
/// or three scheduler bursts landing around the same frame.
class SystemTelemetryController extends Notifier<SystemTelemetrySnapshot>
    with _PeriodicRefresh<SystemTelemetrySnapshot> {
  @override
  SystemTelemetrySnapshot build() {
    _cpuService = ref.watch(cpuUsageServiceProvider);
    _gpuService = ref.watch(gpuUsageServiceProvider);
    _powerService = ref.watch(powerStatusServiceProvider);
    _previousCpu = null;
    startPeriodicRefresh(_interval, _refresh);
    return const SystemTelemetrySnapshot();
  }

  static const Duration _interval = Duration(seconds: 2);

  late CpuUsageService _cpuService;
  late GpuUsageService _gpuService;
  late PowerStatusService _powerService;
  CpuSample? _previousCpu;

  Future<void> _refresh(int generation) async {
    final cpuFuture = _cpuService.read().onError((_, _) => null);
    final gpuFuture = _gpuService.read().onError((_, _) => const <GpuSample>[]);
    final powerFuture = _powerService.read().onError(
      (_, _) => ShellPowerStatus.unknown,
    );
    final cpuSample = await cpuFuture;
    final gpuSamples = await gpuFuture;
    final powerStatus = await powerFuture;
    if (!isRefreshActive(generation)) {
      return;
    }

    var nextCpu = state.cpu;
    final previousCpu = _previousCpu;
    _previousCpu = cpuSample ?? _previousCpu;
    if (cpuSample != null && previousCpu != null) {
      final usage = CpuSample.usageBetween(previousCpu, cpuSample);
      if (usage != null) {
        nextCpu = state.cpu.append(usage, temperatureC: cpuSample.temperatureC);
      }
    }

    var nextGpus = state.gpus;
    if (gpuSamples.isNotEmpty || state.gpus.isNotEmpty) {
      final previous = <String, GpuLoad>{
        for (final load in state.gpus) load.id: load,
      };
      nextGpus = List<GpuLoad>.unmodifiable(<GpuLoad>[
        for (final sample in gpuSamples)
          GpuLoad(
            id: sample.id,
            label: sample.label,
            series: (previous[sample.id]?.series ?? LoadSeries.empty).append(
              sample.usage,
              temperatureC: sample.temperatureC,
            ),
          ),
      ]);
    }
    final nextPower = powerStatus == state.power ? state.power : powerStatus;
    if (identical(nextCpu, state.cpu) &&
        identical(nextGpus, state.gpus) &&
        identical(nextPower, state.power)) {
      return;
    }
    state = SystemTelemetrySnapshot(
      cpu: nextCpu,
      gpus: nextGpus,
      power: nextPower,
    );
  }
}
