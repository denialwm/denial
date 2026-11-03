import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/authentication_protocol.dart';

abstract interface class AuthenticationService {
  Stream<AuthenticationPacket> get events;

  void synchronize();
  void lock();

  /// Starts the preferred credential, the PIN when one is set, or the account
  /// password when [password] is true.
  void begin({bool password = false});
  void respond({
    required int attemptId,
    required int promptSequence,
    required String response,
  });
  void cancel({required int attemptId});

  /// Arms the fingerprint reader only while [offered]; deniald resets it to
  /// offered on every new lock.
  void offerFingerprint(bool offered);
  void dispose();
}

class NativeAuthenticationService implements AuthenticationService {
  NativeAuthenticationService({BinaryMessenger? messenger})
    : _messenger =
          messenger ?? ServicesBinding.instance.defaultBinaryMessenger {
    _messenger.setMessageHandler(
      authenticationToFlutterChannel,
      _handleMessage,
    );
    synchronize();
  }

  final BinaryMessenger _messenger;
  final StreamController<AuthenticationPacket> _events =
      StreamController<AuthenticationPacket>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<AuthenticationPacket> get events => _events.stream;

  @override
  void synchronize() => _send(AuthenticationPacketKind.sync);

  @override
  void lock() => _send(AuthenticationPacketKind.lock);

  @override
  void begin({bool password = false}) => _send(
    AuthenticationPacketKind.begin,
    argument: password ? AuthenticationProtocol.beginPassword : 0,
  );

  @override
  void respond({
    required int attemptId,
    required int promptSequence,
    required String response,
  }) {
    final packet = AuthenticationProtocol.encodeCommand(
      AuthenticationPacketKind.respond,
      attemptId: attemptId,
      argument: promptSequence,
      payload: response,
    );
    if (packet == null || _disposed) {
      return;
    }

    // BinaryMessenger copies the platform message during send. Scrub our
    // mutable packet immediately afterwards; the immutable Dart String is
    // owned only by this call and the UI clears its controller before here.
    _messenger.send(
      authenticationToNativeChannel,
      ByteData.sublistView(packet),
    );
    packet.fillRange(0, packet.length, 0);
  }

  @override
  void cancel({required int attemptId}) {
    _send(AuthenticationPacketKind.cancel, attemptId: attemptId);
  }

  @override
  void offerFingerprint(bool offered) =>
      _send(AuthenticationPacketKind.fingerprint, argument: offered ? 1 : 0);

  void _send(
    AuthenticationPacketKind kind, {
    int attemptId = 0,
    int argument = 0,
  }) {
    if (_disposed) {
      return;
    }
    final packet = AuthenticationProtocol.encodeCommand(
      kind,
      attemptId: attemptId,
      argument: argument,
    );
    if (packet == null) {
      return;
    }
    _messenger
        .send(authenticationToNativeChannel, ByteData.sublistView(packet))
        ?.catchError((Object error) {
          debugPrint('denial authentication bridge unavailable: $error');
          return null;
        });
  }

  Future<ByteData?> _handleMessage(ByteData? data) async {
    if (_disposed) {
      return null;
    }
    final packet = AuthenticationProtocol.decode(data);
    if (packet != null &&
        (packet.kind == AuthenticationPacketKind.state ||
            packet.kind == AuthenticationPacketKind.prompt ||
            packet.kind == AuthenticationPacketKind.result ||
            packet.kind == AuthenticationPacketKind.fingerprintFeedback ||
            packet.kind == AuthenticationPacketKind.credential)) {
      _events.add(packet);
    }
    return null;
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _messenger.setMessageHandler(authenticationToFlutterChannel, null);
    unawaited(_events.close());
  }
}
