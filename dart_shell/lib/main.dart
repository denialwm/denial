import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/config/startup_environment.dart';
import 'src/shell_app.dart';
import 'src/theme/motion.dart';

void main() {
  final environment = StartupEnvironment.capture();
  WidgetsFlutterBinding.ensureInitialized();
  MotionTelemetry.install(
    enabled: environment.flag('DENIA_DART_FRAME_TRACE'),
  );
  runApp(
    ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(environment),
      ],
      child: const DenialShellApp(),
    ),
  );
}
