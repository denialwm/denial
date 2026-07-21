import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../state/shell_controller.dart';
import 'system_io.dart';

final brightnessServiceProvider = Provider<BrightnessService>((ref) {
  return BrightnessService(ref.watch(denialBridgeProvider));
});

/// Reads and applies the panel backlight level.
class BrightnessService {
  const BrightnessService([this._bridge]);

  final DenialBridge? _bridge;
  static const String _currentPath =
      '/sys/class/backlight/panel0-backlight/brightness';
  static const String _maxPath =
      '/sys/class/backlight/panel0-backlight/max_brightness';

  /// Current backlight level as a `[0.01, 1.0]` fraction, or null if unknown.
  Future<double?> readLevel() async {
    final current = await readSysInt(_currentPath);
    final max = await readSysInt(_maxPath);
    if (current == null || max == null || max <= 0) {
      return null;
    }
    return (current / max).clamp(0.01, 1.0).toDouble();
  }

  /// Applies a `[1, 100]` percentage to the backlight.
  Future<void> apply(int percent) {
    _bridge?.setBrightness(percent.clamp(1, 100) / 100);
    return Future<void>.value();
  }
}
