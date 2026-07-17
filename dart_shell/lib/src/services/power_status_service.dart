import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shell_power_status.dart';
import 'system_io.dart';

final powerStatusServiceProvider = Provider<PowerStatusService>((ref) {
  return const PowerStatusService();
});

class PowerStatusService {
  const PowerStatusService();

  static const String _statusPath = '/run/denia-powerd/battery.env';

  Future<ShellPowerStatus> read() async {
    final fields = await readKeyValueFile(_statusPath);
    if (fields.isEmpty) {
      return ShellPowerStatus.unknown;
    }
    return ShellPowerStatus.fromFields(fields);
  }
}
