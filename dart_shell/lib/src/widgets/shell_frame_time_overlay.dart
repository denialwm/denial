import 'dart:math' as math;
import 'dart:ui' show FontFeature, FramePhase, FrameTiming, TimingsCallback;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../config/startup_environment.dart';
import '../localization/denial_localizations.dart';
import '../theme/shell_color_scheme.dart';
import '../theme/shell_theme.dart';

part 'frame_timing_shell_chart.dart';
part 'frame_timing_shell_overlay.dart';

/// Diagnostics are opt-in: even a rate-limited frame overlay participates in
/// frame scheduling and must not tax the production shell it is measuring.
final shellFrameTimingOverlayProvider = Provider<bool>((ref) {
  final environment = ref.watch(startupEnvironmentProvider);
  return environment.flag('DENIAL_FRAME_TIMING_OVERLAY');
});

/// A low-overhead view of the embedded shell engine's real frame timings.
///
/// Unlike a [Ticker]-based meter, this widget does not manufacture a frame on
/// every vsync. It observes completed engine frames and refreshes its own small
/// repaint boundary at most five times per second while other work is active.
