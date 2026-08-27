import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/audio_service.dart';
import 'package:denial_dart_shell/src/services/brightness_service.dart';
import 'package:denial_dart_shell/src/services/power_profile_service.dart';
import 'package:denial_dart_shell/src/services/system_actions_service.dart';
import 'package:denial_dart_shell/src/state/quick_settings.dart';
import 'package:denial_dart_shell/src/state/system_level_hud.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initial hardware reads start concurrently', () async {
    final calls = <String>[];
    final gate = Completer<void>();
    final audio = _BlockingAudioService(DenialBridge(), calls, gate.future);
    final brightness = _BlockingBrightnessService(
      DenialBridge(),
      calls,
      gate.future,
    );
    final power = _BlockingPowerProfileService(calls, gate.future);
    addTearDown(audio.dispose);
    addTearDown(brightness.dispose);
    final container = ProviderContainer.test(
      overrides: [
        brightnessServiceProvider.overrideWithValue(brightness),
        audioServiceProvider.overrideWithValue(audio),
        powerProfileServiceProvider.overrideWithValue(power),
        systemActionsServiceProvider.overrideWithValue(
          const _FakeSystemActionsService(),
        ),
      ],
    );

    container.read(quickSettingsProvider);
    await Future<void>.delayed(Duration.zero);

    expect(calls, unorderedEquals(<String>['brightness', 'volume', 'power']));
    gate.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'volume follows native events without fighting an active gesture',
    () async {
      final bridge = DenialBridge();
      final audio = _FakeAudioService(bridge);
      final brightness = _FakeBrightnessService(DenialBridge());
      addTearDown(audio.dispose);
      addTearDown(brightness.dispose);
      final container = ProviderContainer.test(
        overrides: [
          brightnessServiceProvider.overrideWithValue(brightness),
          audioServiceProvider.overrideWithValue(audio),
          powerProfileServiceProvider.overrideWithValue(
            const _FakePowerProfileService(),
          ),
          systemActionsServiceProvider.overrideWithValue(
            const _FakeSystemActionsService(),
          ),
        ],
      );
      final controller = container.read(quickSettingsProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      audio.emit(level: 0.35);
      expect(container.read(quickSettingsProvider).volume, 0.35);

      controller.beginVolumeInteraction();
      controller.setVolume(0.70);
      audio.emit(level: 0.20);
      expect(
        container.read(quickSettingsProvider).volume,
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
        container.read(quickSettingsProvider).volume,
        0.70,
        reason: 'an unacknowledged optimistic write remains visually stable',
      );

      audio.emit(level: 0.70, requestSerial: write.requestSerial);
      expect(container.read(quickSettingsProvider).volume, 0.70);

      audio.emit(level: 0.55);
      expect(
        container.read(quickSettingsProvider).volume,
        0.55,
        reason: 'external changes resume immediately after acknowledgement',
      );
    },
  );

  test('dashboard volume writes suppress their matching HUD update', () async {
    final bridge = DenialBridge();
    final audio = _FakeAudioService(bridge);
    final brightness = _FakeBrightnessService(DenialBridge());
    addTearDown(audio.dispose);
    addTearDown(brightness.dispose);
    final container = ProviderContainer.test(
      overrides: [
        brightnessServiceProvider.overrideWithValue(brightness),
        audioServiceProvider.overrideWithValue(audio),
        powerProfileServiceProvider.overrideWithValue(
          const _FakePowerProfileService(),
        ),
        systemActionsServiceProvider.overrideWithValue(
          const _FakeSystemActionsService(),
        ),
      ],
    );
    final controller = container.read(quickSettingsProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    controller.beginVolumeInteraction();
    controller.setDashboardVolume(0.70);
    controller.commitDashboardVolume(0.70);
    await Future<void>.delayed(Duration.zero);

    final requestSerial = audio.writes.single.requestSerial;
    expect(
      container
          .read(systemLevelHudAudioSuppressionProvider)
          .consume(requestSerial),
      isTrue,
    );
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
    _states.add(AudioLevelState(level: level, requestSerial: requestSerial));
  }

  Future<void> dispose() async {
    await _states.close();
    bridge.dispose();
  }
}

class _FakeBrightnessService extends BrightnessService {
  _FakeBrightnessService(this.bridge) : super(bridge);

  final DenialBridge bridge;

  @override
  Future<double?> readLevel([DisplayOutput? output]) async => null;

  @override
  Future<void> apply(int percent, [DisplayOutput? output]) async {}

  void dispose() => bridge.dispose();
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
  Future<void> takeScreenshot() async {}
}

class _BlockingAudioService extends _FakeAudioService {
  _BlockingAudioService(super.bridge, this.calls, this.release);

  final List<String> calls;
  final Future<void> release;

  @override
  Future<double?> readLevel() async {
    calls.add('volume');
    await release;
    return null;
  }
}

class _BlockingBrightnessService extends _FakeBrightnessService {
  _BlockingBrightnessService(super.bridge, this.calls, this.release);

  final List<String> calls;
  final Future<void> release;

  @override
  Future<double?> readLevel([DisplayOutput? output]) async {
    calls.add('brightness');
    await release;
    return null;
  }
}

class _BlockingPowerProfileService extends _FakePowerProfileService {
  _BlockingPowerProfileService(this.calls, this.release);

  final List<String> calls;
  final Future<void> release;

  @override
  Future<String?> read() async {
    calls.add('power');
    await release;
    return null;
  }
}
