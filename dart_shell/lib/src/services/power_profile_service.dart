import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'system_io.dart';

/// Canonical power-profile identifiers.
abstract final class PowerProfile {
  static const String powerSave = 'power-save';
  static const String balanced = 'balanced';
  static const String performance = 'performance';

  /// Cycles power-save -> balanced -> performance -> power-save.
  static String next(String current) => switch (current) {
        powerSave => balanced,
        balanced => performance,
        _ => powerSave,
      };

  static String? normalize(String? value) => switch ((value ?? '').trim()) {
        'power-save' ||
        'power-saver' ||
        'powersave' ||
        'power_save' =>
          powerSave,
        'performance' => performance,
        'balanced' => balanced,
        _ => null,
      };
}

final powerProfileServiceProvider = Provider<PowerProfileService>((ref) {
  return const PowerProfileService();
});

/// Reads and writes the system power profile through denia-powerd.
class PowerProfileService {
  const PowerProfileService();

  static const String _envPath = '/run/denia-powerd/power_profile.env';
  static const String _socketPath = '/run/denia-powerd/profile.sock';

  Future<String?> read() async {
    final fields = await readKeyValueFile(_envPath);
    return PowerProfile.normalize(fields['POWER_PROFILE']);
  }

  Future<void> write(String profile) async {
    try {
      final socket = await Socket.connect(
        InternetAddress(_socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 700),
      );
      socket.write('$profile\n');
      await socket.flush();
      socket.destroy();
    } on Object {
      // Powerd may be absent during local runs.
    }
  }
}
