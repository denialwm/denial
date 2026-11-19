import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/power_profile.dart';
import 'power_profiles_client.dart';

export '../models/power_profile.dart';

final powerProfileServiceProvider = Provider<PowerProfileService>((ref) {
  return const PowerProfileService();
});

/// Reads and writes the system power profile through power-profiles-daemon
/// (or tuned-ppd), the same endpoints the desktop power modes use.
class PowerProfileService {
  const PowerProfileService();

  // Created on first use; one system-bus connection for the session.
  static final PowerProfilesClient _client = PowerProfilesClient(
    DBusClient.system(),
  );

  /// The active profile, or null when no power-profile service answers.
  Future<String?> read() => _client.readActiveProfile();

  /// Asks the service for [profile]. Returns whether it accepted it.
  Future<bool> write(String profile) async {
    final endpoint = await _client.resolve();
    if (endpoint == null) {
      return false;
    }
    try {
      await endpoint.setActiveProfile(
        profile == PowerProfile.powerSave ? 'power-saver' : profile,
      );
      return true;
    } on Object {
      return false;
    }
  }
}
