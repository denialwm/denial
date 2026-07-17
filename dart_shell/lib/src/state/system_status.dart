import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../models/battery_status.dart';
import '../models/shell_clock_info.dart';
import '../models/shell_power_status.dart';
import '../services/battery_service.dart';
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

final batteryProvider =
    StateNotifierProvider<BatteryController, BatteryStatus>((ref) {
  return BatteryController(ref.read(batteryServiceProvider));
});

final powerStatusProvider =
    StateNotifierProvider.autoDispose<PowerStatusController, ShellPowerStatus>(
        (ref) {
  return PowerStatusController(ref.read(powerStatusServiceProvider));
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
