import 'dart:typed_data';

import 'package:denial_dart_shell/src/models/denial_cursor_state.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/platform/denial_wire.dart' as wire;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'atomic client cursor surface state crosses the native bridge',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final bridge = DenialBridge()
        ..start(onWindowsChanged: () {}, onWindowActivated: (_) {});
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
          lockEnabled: true,
          lockTimeout: const Duration(minutes: 5),
          dpmsEnabled: true,
          dpmsTimeout: const Duration(minutes: 10),
          suspendEnabled: false,
          suspendTimeout: const Duration(minutes: 30),
        );
        await Future<void>.delayed(Duration.zero);

        final data = packet;
        expect(data, isNotNull);
        expect(data!.lengthInBytes, 32);
        expect(data.getUint8(0), 1);
        expect(data.getUint8(1), 0x03);
        expect(data.buffer.asUint8List(2, 6), everyElement(0));
        expect(data.getUint64(8, Endian.little), 5 * 60 * 1000);
        expect(data.getUint64(16, Endian.little), 10 * 60 * 1000);
        expect(data.getUint64(24, Endian.little), 30 * 60 * 1000);
      } finally {
        bridge.dispose();
        messenger.setMockMessageHandler('denial/idle_policy', null);
      }
    },
  );
}
