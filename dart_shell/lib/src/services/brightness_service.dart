import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../platform/denial_bridge.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import 'system_io.dart';

final brightnessServiceProvider = Provider<BrightnessService>((ref) {
  return BrightnessService(
    ref.watch(denialBridgeProvider),
    defaultOutput: ref.watch(displayLayoutProvider)?.mainOutput,
  );
});

/// Reads and applies monitor brightness through compositor-owned DDC/CI.
class BrightnessService {
  const BrightnessService(this._bridge, {this.defaultOutput});

  final DenialBridge _bridge;
  final DisplayOutput? defaultOutput;
  static const String _currentPath =
      '/sys/class/backlight/panel0-backlight/brightness';
  static const String _maxPath =
      '/sys/class/backlight/panel0-backlight/max_brightness';

  Stream<DenialBrightnessState> get states => _bridge.brightnessStates;

  int? get defaultMonitorId => defaultOutput?.monitorId;

  /// Current backlight level as a `[0.01, 1.0]` fraction, or null if unknown.
  Future<double?> readLevel([DisplayOutput? output]) async {
    final target = output ?? defaultOutput;
    if (target != null) {
      final update = states.firstWhere(
        (state) => state.monitorId == target.monitorId,
      );
      if (!_bridge.requestBrightness(
        monitorId: target.monitorId,
        connector: target.name,
      )) {
        return null;
      }
      try {
        return (await update.timeout(
          const Duration(seconds: 2),
        )).level.clamp(0.01, 1.0).toDouble();
      } on TimeoutException {
        return null;
      }
    }

    // Keep the laptop-panel fallback for development sessions which do not
    // expose the compositor display layout.
    final current = await readSysInt(_currentPath);
    final max = await readSysInt(_maxPath);
    if (current == null || max == null || max <= 0) {
      return null;
    }
    return (current / max).clamp(0.01, 1.0).toDouble();
  }

  /// Applies a `[1, 100]` percentage to the backlight.
  Future<void> apply(int percent, [DisplayOutput? output]) {
    final target = output ?? defaultOutput;
    if (target != null) {
      _bridge.setBrightness(
        monitorId: target.monitorId,
        connector: target.name,
        level: percent.clamp(1, 100) / 100,
      );
    }
    return Future<void>.value();
  }
}
