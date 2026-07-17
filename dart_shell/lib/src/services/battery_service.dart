import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/battery_status.dart';
import 'system_io.dart';

final batteryServiceProvider = Provider<BatteryService>((ref) {
  return const BatteryService();
});

/// Reads the battery state from sysfs.
class BatteryService {
  const BatteryService();

  static const String _capacityPath =
      '/sys/class/power_supply/battery/capacity';
  static const String _statusPath = '/sys/class/power_supply/battery/status';

  Future<BatteryStatus> read() async {
    final capacity = await readSysInt(_capacityPath);
    final status = await readSysString(_statusPath);
    return BatteryStatus(
      capacity: capacity?.clamp(0, 100),
      charging: (status ?? '').toLowerCase() == 'charging',
    );
  }
}
