import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/system_level_hud.dart';

void main() {
  test('system level HUD shows the latest native update and rearms its timeout',
      () async {
    final brightnessUpdates =
        StreamController<DenialBrightnessState>.broadcast(sync: true);
    final audioUpdates =
        StreamController<DenialAudioState>.broadcast(sync: true);
    final controller = SystemLevelHudController(
      brightnessStates: brightnessUpdates.stream,
      audioStates: audioUpdates.stream,
      visibleDuration: const Duration(milliseconds: 30),
    );
    try {
      audioUpdates.add(const DenialAudioState(
        level: 0.20,
        requestSerial: 0,
        completesRead: true,
      ));
      expect(
        controller.state,
        isNull,
        reason: 'a reconciliation read must not look like a volume gesture',
      );

      brightnessUpdates.add(const DenialBrightnessState(
        monitorId: 4,
        level: 0.35,
      ));
      expect(controller.state?.kind, SystemLevelHudKind.brightness);
      expect(controller.state?.monitorId, 4);
      expect(controller.state?.level, 0.35);
      expect(controller.state?.visible, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      audioUpdates.add(const DenialAudioState(
        level: 0.60,
        requestSerial: 17,
      ));
      expect(controller.state?.kind, SystemLevelHudKind.audio);
      expect(controller.state?.monitorId, isNull);
      expect(controller.state?.level, 0.60);
      expect(controller.state?.visible, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        controller.state?.visible,
        isTrue,
        reason: 'the audio update must replace the brightness hide deadline',
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(controller.state?.visible, isFalse);
    } finally {
      controller.dispose();
      await brightnessUpdates.close();
      await audioUpdates.close();
    }
  });
}
