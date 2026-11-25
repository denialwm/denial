import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/src/platform/system_control_protocol.dart';
import 'package:denial_flutter_sdk/src/platform/bridge/control_client.dart';
import 'package:denial_flutter_sdk/src/platform/bridge/platform_transport.dart';
import 'package:test/test.dart';

void main() {
  test('call volume packets carry the actual hardware steps', () {
    final packet = ByteData(12)
      ..setUint32(0, 4, Endian.little)
      ..setUint32(4, 5, Endian.little)
      ..setUint32(8, 9, Endian.little);
    expect(SystemControlProtocol.decodeCallVolume(packet), (
      previous: 4,
      step: 5,
      maximum: 9,
    ));
    expect(SystemControlProtocol.decodeCallVolume(ByteData(11)), isNull);
    expect(SystemControlProtocol.decodeCallVolume(ByteData(12)), isNull);
    packet.setUint32(4, 10, Endian.little);
    expect(SystemControlProtocol.decodeCallVolume(packet), isNull);
    expect(SystemControlProtocol.setCallVolume(257).buffer.asUint8List(), [
      6,
      1,
      1,
      0,
      0,
    ]);
  });

  test('native replies are available without a window subscription', () async {
    final handlers = <String, BridgeMessageHandler?>{};
    final reply = Completer<int>();
    final transport = BridgePlatformTransport((_, packet) async {
      await handlers['native/replies']!(packet);
      return null;
    }, (channel, handler) => handlers[channel] = handler);
    addTearDown(transport.dispose);
    transport.bind({
      'native/replies': (packet) async {
        reply.complete(packet!.getUint32(0));
        return null;
      },
    });

    final id = transport.nextRequestId();
    await transport.send('native/requests', ByteData(4)..setUint32(0, id));
    expect(await reply.future, id);
  });

  test(
    'disposal detaches channels and blocks retained native callbacks',
    () async {
      final handlers = <String, BridgeMessageHandler?>{};
      final detached = <String>[];
      var sent = 0;
      var received = 0;
      final transport = BridgePlatformTransport(
        (_, _) async {
          sent++;
          return null;
        },
        (channel, handler) {
          handlers[channel] = handler;
          if (handler == null) detached.add(channel);
        },
      );
      transport.bind({
        for (final channel in ['wire', 'audio'])
          channel: (_) async {
            received++;
            return null;
          },
      });
      final queuedCallback = handlers['wire']!;
      await queuedCallback(null);
      await transport.send('requests', null);

      transport.dispose();
      transport.dispose();
      await queuedCallback(null);
      await transport.send('requests', null);
      expect(detached, ['wire', 'audio']);
      expect(handlers.values, everyElement(isNull));
      expect(received, 1);
      expect(sent, 1);
      expect(transport.nextRequestId, throwsStateError);
    },
  );

  test(
    'socket RPC shares request IDs and rejects mismatched responses',
    () async {
      final directory = await Directory.systemTemp.createTemp('denial-bridge-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/control.sock';
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      final handlers = <Future<void>>[];
      final subscription = server.listen((socket) {
        handlers.add(() async {
          try {
            final line = await socket
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first;
            final request = jsonDecode(line) as Map<String, dynamic>;
            requests.add(request);
            socket.write(
              jsonEncode({
                'version': 1,
                'id': request['id'] + (requests.length == 2 ? 1 : 0),
                'ok': true,
                'result': {'serial': 9},
              }),
            );
            await socket.flush();
          } finally {
            await socket.close();
          }
        }());
      });
      addTearDown(() async {
        await subscription.cancel();
        await Future.wait(handlers);
      });
      final transport = BridgePlatformTransport(
        (_, _) async => null,
        (_, _) {},
      );
      addTearDown(transport.dispose);
      final control = BridgeControlClient(transport, controlSocketPath: path);
      final platformId = transport.nextRequestId();

      expect(await control.request('outputs.get'), {'serial': 9});
      expect(requests.single['id'], platformId + 1);
      expect(requests.single['method'], 'outputs.get');
      await expectLater(
        control.request('outputs.get'),
        throwsA(
          isA<DenialOutputControlException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      expect(transport.nextRequestId(), platformId + 3);
    },
  );
}
