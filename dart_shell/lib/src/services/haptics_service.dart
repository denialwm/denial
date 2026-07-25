import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../state/shell_controller.dart';

final hapticsServiceProvider = Provider<HapticsService>((ref) {
  final service = HapticsService(ref.watch(denialBridgeProvider));
  ref.onDispose(service.dispose);
  return service;
});

class HapticsService {
  HapticsService(this._bridge) {
    _clock.start();
  }

  final DenialBridge _bridge;
  final Stopwatch _clock = Stopwatch();
  int _lastPulseUs = -_minGapUs;

  static const int _minGapUs = 18000;

  void prewarm() {
    _bridge.prewarmHaptics();
  }

  void pulse() {
    final nowUs = _clock.elapsedMicroseconds;
    if (nowUs - _lastPulseUs < _minGapUs) {
      return;
    }

    _lastPulseUs = nowUs;
    _bridge.sendHapticTap();
  }

  void dispose() {
    // Native deniald owns the haptic transport.
  }
}
