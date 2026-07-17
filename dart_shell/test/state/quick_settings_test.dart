import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/audio_service.dart';
import 'package:denial_dart_shell/src/services/brightness_service.dart';
import 'package:denial_dart_shell/src/services/power_profile_service.dart';
import 'package:denial_dart_shell/src/services/system_actions_service.dart';
import 'package:denial_dart_shell/src/state/quick_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('volume follows native events without fighting an active gesture',
      () async {
    final bridge = DenialBridge();
    final audio = _FakeAudioService(bridge);
    final controller = QuickSettingsController(
      brightness: const _FakeBrightnessService(),
      audio: audio,
      power: const _FakePowerProfileService(),
      actions: const _FakeSystemActionsService(),
    );
    try {
      await Future<void>.delayed(Duration.zero);

      audio.emit(level: 0.35);
      expect(controller.state.volume, 0.35);

      controller.beginVolumeInteraction();
      controller.setVolume(0.70);
      audio.emit(level: 0.20);
      expect(
        controller.state.volume,
        0.70,
        reason: 'external state must not move a thumb under the pointer',
      );

      controller.commitVolume(0.70);
      await Future<void>.delayed(Duration.zero);
      expect(audio.writes, hasLength(1));
      final write = audio.writes.single;
      expect(write.percent, 70);

      audio.emit(level: 0.40);
      expect(
        controller.state.volume,
        0.70,
        reason: 'an unacknowledged optimistic write remains visually stable',
      );

      audio.emit(level: 0.70, requestSerial: write.requestSerial);
      expect(controller.state.volume, 0.70);

      audio.emit(level: 0.55);
      expect(
        controller.state.volume,
        0.55,
        reason: 'external changes resume immediately after acknowledgement',
      );
    } finally {
      controller.dispose();
      await audio.dispose();
    }
  });
}

class _FakeAudioService extends AudioService {
  _FakeAudioService(this.bridge) : super(bridge);

  final DenialBridge bridge;
  final StreamController<AudioLevelState> _states =
      StreamController<AudioLevelState>.broadcast(sync: true);
  final List<({int percent, int requestSerial})> writes = [];

  @override
  Stream<AudioLevelState> get states => _states.stream;

  @override
  Future<double?> readLevel() async => null;

  @override
  Future<void> apply(int percent, {required int requestSerial}) async {
    writes.add((percent: percent, requestSerial: requestSerial));
  }

  void emit({required double level, int requestSerial = 0}) {
    _states.add(AudioLevelState(
      level: level,
      requestSerial: requestSerial,
    ));
  }

  Future<void> dispose() async {
    await _states.close();
    bridge.dispose();
  }
}

class _FakeBrightnessService extends BrightnessService {
  const _FakeBrightnessService();

  @override
  Future<double?> readLevel() async => null;

  @override
  Future<void> apply(int percent) async {}
}

class _FakePowerProfileService extends PowerProfileService {
  const _FakePowerProfileService();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String profile) async {}
}

class _FakeSystemActionsService extends SystemActionsService {
  const _FakeSystemActionsService();

  @override
  Future<void> toggleKeyboard() async {}

  @override
  Future<void> takeScreenshot() async {}
}
