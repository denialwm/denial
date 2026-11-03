import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';

import 'package:denial_sdk/system.dart';

import '../models/shell_clock_info.dart';
import '../models/shell_power_status.dart';
import '../models/system_telemetry.dart';
import '../services/battery_service.dart';
import '../services/cpu_usage_service.dart';
import '../services/gpu_usage_service.dart';
import '../services/power_status_service.dart';
import 'system_telemetry_model.dart';

export '../models/system_telemetry.dart';

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

/// False while every output is powered off: deniald then reports Flutter's
/// `hidden` lifecycle. Nobody can see a sample taken in that state.
final _outputsVisibleProvider = NotifierProvider<_OutputsVisible, bool>(
  _OutputsVisible.new,
);

class _OutputsVisible extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(
      onStateChange: (lifecycle) => state = _visible(lifecycle),
    );
    ref.onDispose(listener.dispose);
    return _visible(WidgetsBinding.instance.lifecycleState);
  }

  static bool _visible(AppLifecycleState? lifecycle) =>
      lifecycle == null ||
      lifecycle == AppLifecycleState.resumed ||
      lifecycle == AppLifecycleState.inactive;
}

mixin _PeriodicRefresh<StateT> on Notifier<StateT> {
  int _refreshGeneration = 0;
  bool _refreshing = false;

  void startPeriodicRefresh(
    Duration interval,
    Future<void> Function(int generation) refresh,
  ) {
    final generation = ++_refreshGeneration;
    _refreshing = false;

    var listened = true;
    var visible = ref.read(_outputsVisibleProvider);

    Future<void> run() async {
      if (!isRefreshActive(generation) ||
          _refreshing ||
          !listened ||
          !visible) {
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

    Timer? timer;
    // Sample only while someone can see the result: a provider whose every
    // listener is hidden (TickerMode off) is paused, and powered-off outputs
    // hide everything. Catch up at once when either ends.
    void update() {
      if (!isRefreshActive(generation) || !listened || !visible) {
        timer?.cancel();
        timer = null;
      } else if (timer == null) {
        timer = Timer.periodic(interval, (_) => unawaited(run()));
        unawaited(run());
      }
    }

    scheduleMicrotask(update);
    ref.listen<bool>(_outputsVisibleProvider, (_, next) {
      visible = next;
      update();
    });
    ref.onCancel(() {
      listened = false;
      update();
    });
    ref.onResume(() {
      listened = true;
      update();
    });
    ref.onDispose(() {
      timer?.cancel();
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
    _model = SystemTelemetryModel();
    startPeriodicRefresh(_interval, _refresh);
    return const SystemTelemetrySnapshot();
  }

  static const Duration _interval = Duration(seconds: 2);

  late CpuUsageService _cpuService;
  late GpuUsageService _gpuService;
  late PowerStatusService _powerService;
  late SystemTelemetryModel _model;

  Future<void> _refresh(int generation) async {
    final (cpuSample, gpuSamples, powerStatus) = await (
      _cpuService.read().onError((_, _) => null),
      _gpuService.read().onError((_, _) => const <GpuSample>[]),
      _powerService.read().onError((_, _) => ShellPowerStatus.unknown),
    ).wait;
    if (!isRefreshActive(generation)) {
      return;
    }

    final next = _model.update(
      state,
      cpuSample: cpuSample,
      gpuSamples: gpuSamples,
      powerStatus: powerStatus,
    );
    if (!identical(next, state)) state = next;
  }
}
