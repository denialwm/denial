import 'dart:convert';
import 'dart:typed_data';

import 'package:denial_dart_shell/src/platform/authentication_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
