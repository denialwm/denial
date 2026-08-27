import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/system_level_hud.dart';

void main() {
  test(
    'system level HUD shows changed levels and rearms its timeout',
    () async {
      final brightnessUpdates =
          StreamController<DenialBrightnessState>.broadcast(sync: true);
      final audioUpdates = StreamController<DenialAudioState>.broadcast(
        sync: true,
      );
      addTearDown(brightnessUpdates.close);
      addTearDown(audioUpdates.close);
      final container = ProviderContainer.test(
        overrides: [
          systemLevelHudSignalsProvider.overrideWithValue((
            audio: audioUpdates.stream,
            brightness: brightnessUpdates.stream,
          )),
          systemLevelHudVisibleDurationProvider.overrideWithValue(
            const Duration(milliseconds: 30),
          ),
        ],
      );
      container.read(systemLevelHudProvider.notifier);
      audioUpdates.add(
        const DenialAudioState(
          level: 0.20,
          requestSerial: 0,
          completesRead: true,
        ),
      );
      expect(
        container.read(systemLevelHudProvider),
        isNull,
        reason: 'a reconciliation read must not look like a volume gesture',
      );

      brightnessUpdates.add(
        const DenialBrightnessState(
          monitorId: 4,
          level: 0.35,
          completesRead: true,
        ),
      );
      expect(
        container.read(systemLevelHudProvider),
        isNull,
        reason: 'a reconciliation read must not look like a brightness gesture',
      );

      brightnessUpdates.add(
        const DenialBrightnessState(monitorId: 4, level: 0.35),
      );
      expect(
        container.read(systemLevelHudProvider)?.kind,
        SystemLevelHudKind.brightness,
      );
      expect(container.read(systemLevelHudProvider)?.monitorId, 4);
      expect(container.read(systemLevelHudProvider)?.level, 0.35);
      expect(container.read(systemLevelHudProvider)?.visible, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      audioUpdates.add(const DenialAudioState(level: 0.60, requestSerial: 17));
      expect(
        container.read(systemLevelHudProvider)?.kind,
        SystemLevelHudKind.audio,
      );
      expect(container.read(systemLevelHudProvider)?.monitorId, isNull);
      expect(container.read(systemLevelHudProvider)?.level, 0.60);
      expect(container.read(systemLevelHudProvider)?.visible, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        container.read(systemLevelHudProvider)?.visible,
        isTrue,
        reason: 'the audio update must replace the brightness hide deadline',
      );

      final audioRevision = container.read(systemLevelHudProvider)!.revision;
      audioUpdates.add(const DenialAudioState(level: 0.60, requestSerial: 0));
      expect(
        container.read(systemLevelHudProvider)?.revision,
        audioRevision,
        reason: 'an unchanged level must not present or rearm the volume HUD',
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(container.read(systemLevelHudProvider)?.visible, isFalse);

      audioUpdates.add(const DenialAudioState(level: 0.65, requestSerial: 0));
      expect(container.read(systemLevelHudProvider)?.visible, isTrue);
      expect(container.read(systemLevelHudProvider)?.level, 0.65);
      expect(
        container.read(systemLevelHudProvider)?.revision,
        audioRevision + 1,
      );

      container.read(systemLevelHudAudioSuppressionProvider).suppress(23);
      audioUpdates.add(const DenialAudioState(level: 0.70, requestSerial: 23));
      expect(
        container.read(systemLevelHudProvider)?.revision,
        audioRevision + 1,
        reason: 'a dashboard volume acknowledgement must not present the HUD',
      );

      audioUpdates.add(const DenialAudioState(level: 0.75, requestSerial: 0));
      expect(container.read(systemLevelHudProvider)?.visible, isTrue);
      expect(container.read(systemLevelHudProvider)?.level, 0.75);
      expect(
        container.read(systemLevelHudProvider)?.revision,
        audioRevision + 2,
        reason: 'later hardware volume changes must still present the HUD',
      );
    },
  );
}
