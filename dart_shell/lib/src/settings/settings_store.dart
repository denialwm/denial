import 'dart:convert';

import '../platform/denial_bridge.dart';
import 'shell_settings.dart';

abstract interface class SettingsStore {
  Future<ShellSettings?> read();

  Future<void> write(ShellSettings settings);
}

abstract interface class SettingsDocumentTransport {
  Future<DenialSettingsDocument> read();

  Future<DenialSettingsDocument> write({
    required int expectedRevision,
    required String document,
  });
}

class DenialSettingsDocumentTransport implements SettingsDocumentTransport {
  const DenialSettingsDocumentTransport(this._bridge);

  final DenialBridge _bridge;

  @override
  Future<DenialSettingsDocument> read() => _bridge.readSettingsDocument();

  @override
  Future<DenialSettingsDocument> write({
    required int expectedRevision,
    required String document,
  }) => _bridge.writeSettingsDocument(
    expectedRevision: expectedRevision,
    document: document,
  );
}

/// Shell-facing projection of deniald's shared settings document.
///
/// The compositor is the only process that opens `settings.json`. This class
/// retains a revision token, sends typed bridge requests, and retries once
/// after a concurrent native keyboard update advances the shared document.
class NativeSettingsStore implements SettingsStore {
  NativeSettingsStore(this._transport);

  final SettingsDocumentTransport _transport;
  Future<void> _writeQueue = Future<void>.value();
  int _revision = 0;

  @override
  Future<ShellSettings?> read() async {
    try {
      return _decode(await _readDocument());
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
  }

  @override
  Future<void> write(ShellSettings settings) {
    final write = _writeQueue.then((_) => _write(settings));
    _writeQueue = write.catchError((_) {});
    return write;
  }

  Future<void> _write(ShellSettings settings) async {
    if (_revision <= 0) {
      await _readDocument();
    }
    final payload =
        '${const JsonEncoder.withIndent('  ').convert(settings.toJson())}\n';
    try {
      final response = await _transport.write(
        expectedRevision: _revision,
        document: payload,
      );
      _revision = response.revision;
    } on StateError {
      // A keyboard update and a shell preference can be committed in either
      // order. Refresh the token and replay the shell projection once; Rust
      // preserves the native-owned keyboard section during this write.
      await _readDocument();
      final response = await _transport.write(
        expectedRevision: _revision,
        document: payload,
      );
      _revision = response.revision;
    }
  }

  Future<DenialSettingsDocument> _readDocument() async {
    final document = await _transport.read();
    if (document.revision <= 0) {
      throw StateError('Denial returned an invalid settings revision');
    }
    _revision = document.revision;
    return document;
  }

  ShellSettings _decode(DenialSettingsDocument document) {
    final decoded = jsonDecode(document.json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Denial settings root is not an object');
    }
    return ShellSettings.fromJson(decoded);
  }
}
