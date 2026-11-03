import 'package:denial_flutter_sdk/service_backends.dart'
    show AuthenticationPacketKind;
import 'package:denial_flutter_sdk/wire.dart'
    show
        AuthenticationProtocol,
        authenticationHeaderBytes,
        authenticationMaxPacketBytes,
        authenticationMaxPayloadBytes;

import 'dart:convert';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/platform.dart';
import 'package:test/test.dart';

void main() {
  test('decodes an offset view without including surrounding bytes', () {
    final packet = AuthenticationProtocol.encodeCommand(
      AuthenticationPacketKind.respond,
      attemptId: 42,
      argument: 7,
      payload: 'A café 日本語',
    )!;
    final backing = Uint8List(packet.length + 13);
    backing.setRange(5, 5 + packet.length, packet);
    final decoded = AuthenticationProtocol.decode(
      ByteData.sublistView(backing, 5, 5 + packet.length),
    )!;
    backing.fillRange(0, backing.length, 0);
    expect(decoded.payload, 'A café 日本語');
    expect(decoded.attemptId, 42);
    expect(decoded.argument, 7);
  });

  test('retains malformed UTF-8 replacement and rejects embedded NUL', () {
    final packet = _eventPacket(
      AuthenticationPacketKind.prompt,
      flags: 1 << 4,
      payload: 'abc',
    );
    packet[authenticationHeaderBytes + 1] = 0xff;
    expect(
      AuthenticationProtocol.decode(ByteData.sublistView(packet))?.payload,
      'a\uFFFDc',
    );
    packet[authenticationHeaderBytes + 1] = 0;
    expect(AuthenticationProtocol.decode(ByteData.sublistView(packet)), isNull);
  });

  test('round-trips bounded commands with attempt and prompt identity', () {
    final encoded = AuthenticationProtocol.encodeCommand(
      AuthenticationPacketKind.respond,
      attemptId: 42,
      argument: 7,
      payload: 'correct horse',
    )!;

    final decoded = AuthenticationProtocol.decode(
      ByteData.sublistView(encoded),
    )!;
    expect(decoded.kind, AuthenticationPacketKind.respond);
    expect(decoded.attemptId, 42);
    expect(decoded.argument, 7);
    expect(decoded.payload, 'correct horse');
  });

  test('rejects malformed, oversized, truncated, and NUL-bearing packets', () {
    expect(AuthenticationProtocol.decode(null), isNull);
    expect(AuthenticationProtocol.decode(ByteData(23)), isNull);
    expect(
      AuthenticationProtocol.decode(ByteData(authenticationMaxPacketBytes + 1)),
      isNull,
    );
    expect(
      AuthenticationProtocol.encodeCommand(
        AuthenticationPacketKind.respond,
        payload: List<String>.filled(
          authenticationMaxPayloadBytes + 1,
          'x',
        ).join(),
      ),
      isNull,
    );
    expect(
      AuthenticationProtocol.encodeCommand(
        AuthenticationPacketKind.respond,
        payload: 'before\u0000after',
      ),
      isNull,
    );

    final valid = _eventPacket(
      AuthenticationPacketKind.state,
      flags: 3,
      payload: 'ready',
    );
    expect(
      AuthenticationProtocol.decode(
        ByteData.sublistView(valid, 0, valid.length - 1),
      ),
      isNull,
    );
    valid[0] = 0;
    expect(AuthenticationProtocol.decode(ByteData.sublistView(valid)), isNull);
  });

  test('decodes native state, prompt, and result flags', () {
    final prompt = AuthenticationProtocol.decode(
      ByteData.sublistView(
        _eventPacket(
          AuthenticationPacketKind.prompt,
          flags: 1 | 2 | 4 | (1 << 4),
          attemptId: 9,
          argument: 11,
          payload: 'Password:',
        ),
      ),
    )!;
    expect(prompt.locked, isTrue);
    expect(prompt.available, isTrue);
    expect(prompt.busy, isTrue);
    expect(prompt.promptStyle, AuthenticationPromptStyle.echoOff);
    expect(prompt.attemptId, 9);
    expect(prompt.argument, 11);

    final result = AuthenticationProtocol.decode(
      ByteData.sublistView(
        _eventPacket(
          AuthenticationPacketKind.result,
          flags: 2 | (1 << 4),
          attemptId: 9,
          payload: 'Authentication successful',
        ),
      ),
    )!;
    expect(result.locked, isFalse);
    expect(result.success, isTrue);
    expect(result.cancelled, isFalse);
  });

  test('decodes PIN prompts and credential packets', () {
    final prompt = AuthenticationProtocol.decode(
      ByteData.sublistView(
        _eventPacket(
          AuthenticationPacketKind.prompt,
          flags: 1 | 2 | 4 | (5 << 4),
          attemptId: 4,
          argument: 2,
          payload: 'PIN',
        ),
      ),
    )!;
    expect(prompt.promptStyle, AuthenticationPromptStyle.pin);
    expect(prompt.promptStyle!.requiresResponse, isTrue);

    final credential = AuthenticationProtocol.decode(
      ByteData.sublistView(
        _eventPacket(
          AuthenticationPacketKind.credential,
          flags: 1 | 2,
          argument: 6,
        ),
      ),
    )!;
    expect(credential.kind, AuthenticationPacketKind.credential);
    expect(credential.argument, 6);
    expect(
      AuthenticationProtocol.encodeCommand(AuthenticationPacketKind.credential),
      isNull,
    );

    final begin = AuthenticationProtocol.encodeCommand(
      AuthenticationPacketKind.begin,
      argument: AuthenticationProtocol.beginPassword,
    )!;
    expect(
      ByteData.sublistView(begin).getUint32(16, Endian.little),
      AuthenticationProtocol.beginPassword,
    );
  });
}

Uint8List _eventPacket(
  AuthenticationPacketKind kind, {
  int flags = 0,
  int attemptId = 0,
  int argument = 0,
  String payload = '',
}) {
  final payloadBytes = utf8.encode(payload);
  final bytes = Uint8List(authenticationHeaderBytes + payloadBytes.length);
  bytes.setRange(0, 4, const <int>[0x44, 0x41, 0x55, 0x54]);
  ByteData.sublistView(bytes)
    ..setUint16(4, 1, Endian.little)
    ..setUint8(6, kind.value)
    ..setUint8(7, flags)
    ..setUint64(8, attemptId, Endian.little)
    ..setUint32(16, argument, Endian.little)
    ..setUint32(20, payloadBytes.length, Endian.little);
  bytes.setRange(authenticationHeaderBytes, bytes.length, payloadBytes);
  return bytes;
}
