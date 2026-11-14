import 'dart:typed_data';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/wire.dart' as wire;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shared bridge receives replies without the window controller',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, (
        data,
      ) async {
        final request = wire.Envelope(
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        final reply = wire.EnvelopeObjectBuilder(
          protocolVersion: 1,
          sequence: 1,
          requestId: request.requestId,
          payloadType: wire.PayloadTypeId.SettingsResponse,
          payload: wire.SettingsResponseObjectBuilder(
            kind: wire.SettingsResponseKind.Document,
            success: true,
            revision: 7,
            document: '{"version":28}',
          ),
        ).toBytes('DENW');
        await messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          ByteData.sublistView(reply),
          null,
        );
        return null;
      });
      final container = ProviderContainer();
      try {
        final bridge = container.read(denialBridgeProvider);
        final settings = await bridge.readSettingsDocument();
        expect(settings.revision, 7);
        expect(settings.json, '{"version":28}');
        expect(container.exists(shellControllerProvider), isFalse);
      } finally {
        container.dispose();
        messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
      }
    },
  );

  for (final hasPendingRead in [false, true]) {
    test(
      'audio listener reads wait for a new response ($hasPendingRead)',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMessageHandler('denial/audio', (_) async => null);
        final bridge = DenialBridge();
        final states = <DenialAudioState>[];
        Future<double?>? listenerRead;
        var listenerReadCompleted = false;
        final subscription = bridge.audioStates.listen((state) {
          states.add(state);
          listenerRead ??= bridge.readAudioLevel().then((value) {
            listenerReadCompleted = true;
            return value;
          });
        });
        try {
          final initialRead = hasPendingRead ? bridge.readAudioLevel() : null;
          await messenger.handlePlatformMessage(
            'denial/audio_state',
            ByteData(1)..setUint8(0, 25),
            null,
          );
          await Future<void>.delayed(Duration.zero);
          if (initialRead != null) expect(await initialRead, 0.25);
          expect(states.single.completesRead, hasPendingRead);
          expect(listenerReadCompleted, isFalse);

          await messenger.handlePlatformMessage(
            'denial/audio_state',
            ByteData(1)..setUint8(0, 75),
            null,
          );
          expect(await listenerRead, 0.75);
          expect(states.last.completesRead, isTrue);
        } finally {
          await subscription.cancel();
          bridge.dispose();
          messenger.setMockMessageHandler('denial/audio', null);
        }
      },
    );
  }

  test(
    'atomic client cursor surface state crosses the native bridge',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final bridge = DenialBridge();
      final states = <DenialCursorState>[];
      final subscription = bridge.cursorStates.listen(states.add);

      try {
        final envelope = wire.EnvelopeObjectBuilder(
          protocolVersion: 1,
          sequence: 41,
          requestId: 0,
          payloadType: wire.PayloadTypeId.CursorState,
          payload: wire.CursorStateObjectBuilder(
            epoch: 17,
            kind: wire.CursorStateKind.Surface,
            hotspot: wire.WirePointObjectBuilder(x: 3.5, y: 5.25),
            surfaces: <wire.SurfaceLayerObjectBuilder>[
              wire.SurfaceLayerObjectBuilder(
                surfaceId: 91,
                parentSurfaceId: 0,
                popupRootSurfaceId: 0,
                role: wire.SurfaceRole.Root,
                textureId: 501,
                width: 32,
                height: 48,
                surfaceX: 0,
                surfaceY: 0,
                surfaceWidth: 16,
                surfaceHeight: 24,
                textureSourceX: 0,
                textureSourceY: 0,
                textureSourceWidth: 32,
                textureSourceHeight: 48,
                transform: 0,
                scale120: 240,
                compositionOrder: 0,
                opacity: 1,
                opaque: false,
              ),
            ],
          ),
        ).toBytes('DENW');

        await messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          ByteData.sublistView(envelope),
          null,
        );

        expect(states, hasLength(1));
        expect(states.single.epoch, 17);
        expect(states.single.kind, DenialCursorStateKind.surface);
        expect(states.single.hotspot, const Offset(3.5, 5.25));
        expect(states.single.surfaceLayers.single.surfaceId, 91);
        expect(states.single.surfaceLayers.single.textureId, 501);
        expect(states.single.surfaceLayers.single.scale120, 240);
      } finally {
        await subscription.cancel();
        bridge.dispose();
      }
    },
  );

  test(
    'idle policy packet preserves optional actions and timeout order',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      ByteData? packet;
      messenger.setMockMessageHandler('denial/idle_policy', (message) async {
        packet = message;
        return null;
      });
      final bridge = DenialBridge();

      try {
        bridge.setIdlePolicy(
          powerButtonAction: PowerButtonAction.hibernate,
          powerButtonLongPressAction: PowerButtonLongPressAction.powerMenu,
          lockEnabled: true,
          lockTimeout: const Duration(minutes: 5),
          dpmsEnabled: true,
          dpmsTimeout: const Duration(minutes: 10),
          suspendEnabled: false,
          suspendTimeout: const Duration(minutes: 30),
          suspendMode: SuspendMode.deep,
        );
        await Future<void>.delayed(Duration.zero);

        final data = packet;
        expect(data, isNotNull);
        expect(data!.lengthInBytes, 32);
        expect(data.getUint8(0), 5);
        expect(data.getUint8(1), 0x03);
        expect(data.getUint8(2), 3);
        expect(data.getUint8(3), 0x12);
        expect(data.buffer.asUint8List(4, 4), everyElement(0));
        expect(data.getUint64(8, Endian.little), 5 * 60 * 1000);
        expect(data.getUint64(16, Endian.little), 10 * 60 * 1000);
        expect(data.getUint64(24, Endian.little), 30 * 60 * 1000);
      } finally {
        bridge.dispose();
        messenger.setMockMessageHandler('denial/idle_policy', null);
      }
    },
  );

  test('software dimming requests and state cross the native bridge', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ByteData? packet;
    messenger.setMockMessageHandler('denial/software_dimming', (message) async {
      packet = message;
      return null;
    });
    final bridge = DenialBridge();
    final states = <DenialSoftwareDimmingState>[];
    final subscription = bridge.softwareDimmingStates.listen(states.add);

    try {
      final read = bridge.readSoftwareDimmingLevel(monitorId: 42);
      await Future<void>.delayed(Duration.zero);

      final readPacket = packet;
      expect(readPacket, isNotNull);
      expect(readPacket!.lengthInBytes, 10);
      expect(readPacket.getUint8(0), 0);
      expect(readPacket.getInt64(1, Endian.little), 42);
      expect(readPacket.getUint8(9), 100);

      final response = ByteData(10)
        ..setInt64(0, 42, Endian.little)
        ..setUint8(8, 37)
        ..setUint8(9, 1);
      await messenger.handlePlatformMessage(
        'denial/software_dimming_state',
        response,
        null,
      );

      expect(await read, 0.37);
      expect(states, hasLength(1));
      expect(states.single.monitorId, 42);
      expect(states.single.level, 0.37);
      expect(states.single.supported, isTrue);
      expect(states.single.completesRead, isTrue);

      expect(bridge.setSoftwareDimming(monitorId: 42, level: 0.314), isTrue);
      await Future<void>.delayed(Duration.zero);
      final setPacket = packet;
      expect(setPacket, isNotNull);
      expect(setPacket!.getUint8(0), 1);
      expect(setPacket.getInt64(1, Endian.little), 42);
      expect(setPacket.getUint8(9), 31);
    } finally {
      await subscription.cancel();
      bridge.dispose();
      messenger.setMockMessageHandler('denial/software_dimming', null);
    }
  });
}
