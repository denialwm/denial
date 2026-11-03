import 'dart:convert';
import 'dart:typed_data';

const String authenticationToNativeChannel = 'denial/authentication';
const String authenticationToFlutterChannel = 'denial/authentication_state';
const int authenticationHeaderBytes = 24;
const int authenticationMaxPayloadBytes = 4096;
const int authenticationMaxPacketBytes =
    authenticationHeaderBytes + authenticationMaxPayloadBytes;
const int _authenticationVersion = 1;
const int _authenticationMagic = 0x54554144; // DAUT, little-endian.

enum AuthenticationPacketKind {
  sync(1),
  lock(2),
  begin(3),
  respond(4),
  cancel(5),

  /// Argument 1: the lock screen offers the fingerprint; 0: it asks for a
  /// typed credential and the reader must not answer.
  fingerprint(6),
  state(0x81),
  prompt(0x82),
  result(0x83),
  fingerprintFeedback(0x84),

  /// Argument: the configured PIN length, 0 when only the password is set.
  credential(0x85);

  const AuthenticationPacketKind(this.value);
  final int value;

  static AuthenticationPacketKind? fromValue(int value) {
    for (final kind in values) {
      if (kind.value == value) {
        return kind;
      }
    }
    return null;
  }
}

enum AuthenticationPromptStyle {
  echoOff(1),
  echoOn(2),
  info(3),
  error(4),

  /// Denial's numeric lock PIN prompt; PAM never sends it.
  pin(5);

  const AuthenticationPromptStyle(this.value);
  final int value;

  bool get requiresResponse =>
      this == AuthenticationPromptStyle.echoOff ||
      this == AuthenticationPromptStyle.echoOn ||
      this == AuthenticationPromptStyle.pin;

  static AuthenticationPromptStyle? fromValue(int value) {
    for (final style in values) {
      if (style.value == value) {
        return style;
      }
    }
    return null;
  }
}

class AuthenticationPacket {
  const AuthenticationPacket({
    required this.kind,
    required this.locked,
    required this.available,
    required this.busy,
    required this.rateLimited,
    required this.attemptId,
    required this.argument,
    required this.payload,
    this.promptStyle,
    this.success = false,
    this.cancelled = false,
  });

  final AuthenticationPacketKind kind;
  final bool locked;
  final bool available;
  final bool busy;
  final bool rateLimited;
  final int attemptId;
  final int argument;
  final String payload;
  final AuthenticationPromptStyle? promptStyle;
  final bool success;
  final bool cancelled;
}

abstract final class AuthenticationProtocol {
  /// Begin argument that asks for the account password even when a PIN is set.
  static const int beginPassword = 1;

  static const int _stateLocked = 1 << 0;
  static const int _stateAvailable = 1 << 1;
  static const int _stateBusy = 1 << 2;
  static const int _stateRateLimited = 1 << 3;
  static const int _resultSuccess = 1 << 4;
  static const int _resultCancelled = 1 << 5;
  static const int _promptStyleShift = 4;

  static AuthenticationPacket? decode(ByteData? data) {
    if (data == null ||
        data.lengthInBytes < authenticationHeaderBytes ||
        data.lengthInBytes > authenticationMaxPacketBytes) {
      return null;
    }
    if (data.getUint32(0, Endian.little) != _authenticationMagic ||
        data.getUint16(4, Endian.little) != _authenticationVersion) {
      return null;
    }
    final kind = AuthenticationPacketKind.fromValue(data.getUint8(6));
    if (kind == null) {
      return null;
    }
    final payloadLength = data.getUint32(20, Endian.little);
    if (payloadLength > authenticationMaxPayloadBytes ||
        authenticationHeaderBytes + payloadLength != data.lengthInBytes) {
      return null;
    }
    // Decoding is synchronous and returns a String, so the byte view never
    // escapes this call and no intermediate payload copy is needed.
    final payloadBytes = Uint8List.sublistView(data, authenticationHeaderBytes);
    if (payloadBytes.contains(0)) {
      return null;
    }
    final flags = data.getUint8(7);
    AuthenticationPromptStyle? promptStyle;
    if (kind == AuthenticationPacketKind.prompt) {
      promptStyle = AuthenticationPromptStyle.fromValue(
        flags >> _promptStyleShift,
      );
      if (promptStyle == null) {
        return null;
      }
    }
    return AuthenticationPacket(
      kind: kind,
      locked: flags & _stateLocked != 0,
      available: flags & _stateAvailable != 0,
      busy: flags & _stateBusy != 0,
      rateLimited: flags & _stateRateLimited != 0,
      attemptId: data.getUint64(8, Endian.little),
      argument: data.getUint32(16, Endian.little),
      payload: utf8.decode(payloadBytes, allowMalformed: true),
      promptStyle: promptStyle,
      success: flags & _resultSuccess != 0,
      cancelled: flags & _resultCancelled != 0,
    );
  }

  static Uint8List? encodeCommand(
    AuthenticationPacketKind kind, {
    int attemptId = 0,
    int argument = 0,
    String payload = '',
  }) {
    if (kind == AuthenticationPacketKind.state ||
        kind == AuthenticationPacketKind.prompt ||
        kind == AuthenticationPacketKind.result ||
        kind == AuthenticationPacketKind.fingerprintFeedback ||
        kind == AuthenticationPacketKind.credential ||
        attemptId < 0 ||
        argument < 0) {
      return null;
    }
    final payloadBytes = utf8.encode(payload);
    if (payloadBytes.length > authenticationMaxPayloadBytes ||
        payloadBytes.contains(0)) {
      return null;
    }
    final bytes = Uint8List(authenticationHeaderBytes + payloadBytes.length);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, _authenticationMagic, Endian.little);
    data.setUint16(4, _authenticationVersion, Endian.little);
    data.setUint8(6, kind.value);
    data.setUint8(7, 0);
    data.setUint64(8, attemptId, Endian.little);
    data.setUint32(16, argument, Endian.little);
    data.setUint32(20, payloadBytes.length, Endian.little);
    bytes.setRange(authenticationHeaderBytes, bytes.length, payloadBytes);
    payloadBytes.fillRange(0, payloadBytes.length, 0);
    return bytes;
  }
}
