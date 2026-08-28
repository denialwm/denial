import 'dart:convert';

import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes writes through the Rust-owned document transport', () async {
    final transport = _MemorySettingsTransport();
    final store = NativeSettingsStore(transport);
    const first = ShellSettings(
      appearance: ShellAppearanceSettings(cornerRadiusScale: 0.75),
    );
    const latest = ShellSettings(
      appearance: ShellAppearanceSettings(cornerRadiusScale: 1.5),
    );

    await Future.wait(<Future<void>>[store.write(first), store.write(latest)]);

    expect(await store.read(), latest);
    expect(transport.maximumConcurrentWrites, 1);
    expect(
      jsonDecode(transport.document)['version'],
      ShellSettings.schemaVersion,
    );
  });

  test(
    'refreshes and retries after a shared-document revision conflict',
    () async {
      final transport = _MemorySettingsTransport()..conflictNextWrite = true;
      final store = NativeSettingsStore(transport);
      const settings = ShellSettings(
        appearance: ShellAppearanceSettings(cornerRadiusScale: 1.25),
      );

      await store.write(settings);

      expect(transport.writeAttempts, 2);
      expect(await store.read(), settings);
    },
  );

  test('malformed native documents are reported to the controller', () async {
    final transport = _MemorySettingsTransport()..document = '{ not JSON';
    final store = NativeSettingsStore(transport);

    await expectLater(store.read(), throwsFormatException);
  });
}

class _MemorySettingsTransport implements SettingsDocumentTransport {
  int revision = 1;
  String document = '${jsonEncode(const ShellSettings().toJson())}\n';
  bool conflictNextWrite = false;
  int writeAttempts = 0;
  int _concurrentWrites = 0;
  int maximumConcurrentWrites = 0;

  @override
  Future<DenialSettingsDocument> read() async {
    return DenialSettingsDocument(revision: revision, json: document);
  }

  @override
  Future<DenialSettingsDocument> write({
    required int expectedRevision,
    required String document,
  }) async {
    writeAttempts += 1;
    _concurrentWrites += 1;
    maximumConcurrentWrites = maximumConcurrentWrites < _concurrentWrites
        ? _concurrentWrites
        : maximumConcurrentWrites;
    await Future<void>.delayed(Duration.zero);
    _concurrentWrites -= 1;
    if (conflictNextWrite) {
      conflictNextWrite = false;
      revision += 1;
      throw StateError('settings revision conflict');
    }
    if (expectedRevision != revision) {
      throw StateError('settings revision conflict');
    }
    revision += 1;
    this.document = document;
    return DenialSettingsDocument(revision: revision, json: document);
  }
}
