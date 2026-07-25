import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';

enum ShellProfile {
  mobile,
  desktop;

  static ShellProfile fromEnvironment(Map<String, String> environment) {
    final configured = environment['DENIA_SHELL_PROFILE']?.trim().toLowerCase();
    return configured == 'desktop' ? ShellProfile.desktop : ShellProfile.mobile;
  }
}

final shellProfileProvider = Provider<ShellProfile>((ref) {
  return ShellProfile.fromEnvironment(
    ref.watch(startupEnvironmentProvider).values,
  );
});
