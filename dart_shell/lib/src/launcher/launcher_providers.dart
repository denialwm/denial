import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import 'runtime_paths.dart';
import 'services/screen_power_service.dart';

final runtimePathsProvider = Provider<RuntimePaths>((ref) {
  return RuntimePaths(
    environment: ref.watch(startupEnvironmentProvider).values,
  );
});

final homeTitleProvider = Provider<String>((ref) => 'denia-home');

final screenPowerServiceProvider = Provider<ScreenPowerService>((ref) {
  return ScreenPowerService(paths: ref.watch(runtimePathsProvider));
});
