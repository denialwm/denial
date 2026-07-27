import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';

enum ShellProfile {
  mobile,
  desktop;

  /// Selects the mobile shell only when it was requested explicitly.
  ///
  /// The compositor is a desktop product, so a missing or malformed
  /// environment must never make a direct `deniald` launch fall back to the
  /// mobile development shell.
  static ShellProfile fromEnvironment(Map<String, String> environment) {
    return environment['DENIA_SHELL_PROFILE'] == 'mobile'
        ? ShellProfile.mobile
        : ShellProfile.desktop;
  }
}

final shellProfileProvider = Provider<ShellProfile>((ref) {
  return ShellProfile.fromEnvironment(
    ref.watch(startupEnvironmentProvider).values,
  );
});
