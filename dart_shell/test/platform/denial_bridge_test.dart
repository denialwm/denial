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
}
