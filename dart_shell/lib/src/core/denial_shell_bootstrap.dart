import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_window_render_telemetry.dart';
import '../local_apps/local_flutter_application.dart';
import '../theme/motion.dart';

typedef DenialLocalApplicationsBuilder =
    List<LocalFlutterApplication> Function(StartupEnvironment environment);

/// Starts a Denial shell with the complete required process configuration.
///
/// A custom shell entry point normally needs only this function and a
/// [DenialShell] widget. Startup environment capture, Flutter binding setup,
/// diagnostics, Riverpod ownership, and local application registration stay
/// consistent with the stock shell.
void runDenialShell({
  required Widget shell,
  DenialLocalApplicationsBuilder? localApplications,
}) {
  final environment = StartupEnvironment.capture();
  WidgetsFlutterBinding.ensureInitialized();
  MotionTelemetry.install(enabled: environment.flag('DENIA_DART_FRAME_TRACE'));
  DesktopWindowRenderTelemetry.install(
    enabled: environment.flag('DENIA_RENDER_AUDIT'),
  );
  runApp(
    ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(environment),
        localFlutterApplicationsProvider.overrideWithValue(
          localApplications?.call(environment) ??
              const <LocalFlutterApplication>[],
        ),
      ],
      child: shell,
    ),
  );
}
