import 'dart:typed_data' show ByteData;

import 'package:flutter/gestures.dart' show GestureBinding;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show ServicesBinding;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_window_render_telemetry.dart';
import '../launcher/runtime_paths.dart';
import '../local_apps/local_flutter_application.dart';

import 'package:denial_flutter_sdk/motion.dart';

import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/wallpaper.dart';

/// Where each frame samples touch, relative to its start. deniald stamps
/// touch with the panel's own sample time, so the newest sample is one panel
/// interval plus its delivery old when a frame starts. Sampling earlier than
/// that always interpolates between two real samples; sampling later falls
/// back to the newest one, which moves the content in uneven steps.
const Duration _touchSamplingOffset = Duration(microseconds: -6000);

/// Tells deniald while the shell animates, so a platform that lets Denial
/// raise its GPU clock holds it for motion that no input drives, such as an
/// arriving banner. An animation is a ticker that has scheduled the next
/// frame; a one-off frame callback is not, so two consecutive frames are
/// required. Only changes are sent, never one message per frame.
abstract final class _AnimationActivity {
  static const String _channel = 'denial/animation';
  static final ByteData _started = ByteData(1)..setUint8(0, 1);
  static final ByteData _stopped = ByteData(1);
  static int _frames = 0;
  static bool _reported = false;

  static void install() =>
      SchedulerBinding.instance.addPersistentFrameCallback(_frame);

  static void _frame(Duration _) {
    if (SchedulerBinding.instance.transientCallbackCount == 0) {
      _frames = 0;
      if (_reported) _report(false);
      return;
    }
    if (++_frames >= 2 && !_reported) _report(true);
  }

  static void _report(bool animating) {
    _reported = animating;
    ServicesBinding.instance.defaultBinaryMessenger.send(
      _channel,
      animating ? _started : _stopped,
    );
  }
}

typedef DenialLocalApplicationsBuilder = List<LocalFlutterApplication> Function(
  StartupEnvironment environment,
);

/// Starts a Denial shell with the complete required process configuration.
///
/// The generated entry point passes its selected ShellApplication's root here.
/// Startup environment capture, Flutter binding setup, diagnostics, Riverpod
/// ownership, and local application registration are independent of stock UI.
Future<void> runDenialShell({
  required Widget shell,
  DenialLocalApplicationsBuilder? localApplications,
}) async {
  final environment = StartupEnvironment.capture();
  WidgetsFlutterBinding.ensureInitialized();
  GestureBinding.instance.samplingOffset = _touchSamplingOffset;
  _AnimationActivity.install();
  MotionTelemetry.install(enabled: environment.flag('DENIAL_DART_FRAME_TRACE'));
  DesktopWindowRenderTelemetry.install(
    enabled: environment.flag('DENIAL_RENDER_AUDIT'),
  );
  final wallpaperStore = WallpaperStore(
    RuntimePaths(environment: environment.values),
  );
  final initialWallpaper =
      await wallpaperStore.read() ?? WallpaperAssignment.initial();
  runApp(
    ProviderScope(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(environment),
        wallpaperStoreProvider.overrideWithValue(wallpaperStore),
        initialWallpaperAssignmentProvider.overrideWithValue(initialWallpaper),
        localFlutterApplicationsProvider.overrideWithValue(
          localApplications?.call(environment) ??
              const <LocalFlutterApplication>[],
        ),
      ],
      child: shell,
    ),
  );
}
