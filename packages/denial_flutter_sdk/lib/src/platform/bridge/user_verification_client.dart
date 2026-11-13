import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';

/// A sheet a client asked for, such as an Android app asking for the screen
/// lock. The shell shows it; the client checks what the user types.
final class DenialUserVerification {
  const DenialUserVerification({
    required this.id,
    required this.pinLength,
    required this.passwordAllowed,
    required this.fingerprint,
    required this.app,
    required this.title,
    required this.description,
  });

  final int id;

  /// The PIN's length; 0 when the sheet cannot ask for the PIN.
  final int pinLength;
  final bool passwordAllowed;

  /// The client also verifies a fingerprint for this prompt: the sheet
  /// starts folded behind a button to the PIN or password.
  final bool fingerprint;

  /// Who asks; may be empty.
  final String app;

  /// What it asked with; may be empty.
  final String title;
  final String description;

  bool get pinAllowed => pinLength > 0;
}

sealed class DenialUserVerificationEvent {
  const DenialUserVerificationEvent(this.id);
  final int id;
}

final class DenialUserVerificationShown extends DenialUserVerificationEvent {
  DenialUserVerificationShown(this.request) : super(request.id);
  final DenialUserVerification request;
}

/// What the user typed did not prove them; ask again after [retry].
final class DenialUserVerificationRejected extends DenialUserVerificationEvent {
  const DenialUserVerificationRejected(super.id, this.retry);
  final Duration retry;
}

/// The fingerprint gave way: a folded sheet opens on the PIN or password.
final class DenialUserVerificationOpened extends DenialUserVerificationEvent {
  const DenialUserVerificationOpened(super.id);
}

/// The sheet is done: [accepted] when the credential proved the user.
final class DenialUserVerificationClosed extends DenialUserVerificationEvent {
  const DenialUserVerificationClosed(super.id, {required this.accepted});
  final bool accepted;
}

/// `denial/user_verification`, as deniald's `user_verify.rs` describes it.
final class BridgeUserVerificationClient {
  BridgeUserVerificationClient(this._context);

  final BridgeContext _context;
  static const String channel = 'denial/user_verification';
  static const int _show = 1;
  static const int _rejected = 2;
  static const int _close = 3;
  static const int _open = 4;
  static const int _credential = 1;
  static const int _cancel = 2;
  static const int _sync = 3;
  static const int _pin = 1;
  static const int _password = 2;

  final StreamController<DenialUserVerificationEvent> _events =
      StreamController<DenialUserVerificationEvent>.broadcast(sync: true);

  Stream<DenialUserVerificationEvent> get events => _events.stream;

  Future<ByteData?> handleMessage(ByteData? data) async {
    if (data == null || data.lengthInBytes < 5 || _events.isClosed) {
      return null;
    }
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final id = data.getUint32(1, Endian.little);
    switch (data.getUint8(0)) {
      case _show when data.lengthInBytes >= 8:
        var offset = 8;
        String? text() {
          if (offset + 2 > bytes.length) return null;
          final length = data.getUint16(offset, Endian.little);
          offset += 2;
          if (offset + length > bytes.length) return null;
          final value = utf8.decode(
            bytes.sublist(offset, offset + length),
            allowMalformed: true,
          );
          offset += length;
          return value;
        }

        final app = text();
        final title = text();
        final description = text();
        if (app == null || title == null || description == null) return null;
        _events.add(
          DenialUserVerificationShown(
            DenialUserVerification(
              id: id,
              pinLength: data.getUint8(5),
              passwordAllowed: data.getUint8(6) != 0,
              fingerprint: data.getUint8(7) != 0,
              app: app,
              title: title,
              description: description,
            ),
          ),
        );
      case _rejected when data.lengthInBytes == 9:
        _events.add(
          DenialUserVerificationRejected(
            id,
            Duration(milliseconds: data.getUint32(5, Endian.little)),
          ),
        );
      case _close when data.lengthInBytes == 6:
        _events.add(
          DenialUserVerificationClosed(id, accepted: data.getUint8(5) != 0),
        );
      case _open when data.lengthInBytes == 5:
        _events.add(DenialUserVerificationOpened(id));
    }
    return null;
  }

  /// Sends what the user typed to the asking client.
  void submit(int id, {required bool pin, required String secret}) {
    final encoded = utf8.encode(secret);
    final record = Uint8List(6 + encoded.length)
      ..[0] = _credential
      ..[5] = pin ? _pin : _password;
    ByteData.sublistView(record).setUint32(1, id, Endian.little);
    record.setRange(6, record.length, encoded);
    encoded.fillRange(0, encoded.length, 0);
    _send(ByteData.sublistView(record));
  }

  /// The user closed the sheet.
  void cancel(int id) {
    final data = ByteData(5)
      ..setUint8(0, _cancel)
      ..setUint32(1, id, Endian.little);
    _send(data);
  }

  /// Asks deniald for the sheet showing, after the shell started.
  void sync() => _send(ByteData(1)..setUint8(0, _sync));

  void _send(ByteData data) {
    _context.platform.send(channel, data)?.catchError((Object _) => null);
  }
}
