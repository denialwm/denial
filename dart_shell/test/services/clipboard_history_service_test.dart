import 'dart:convert';
import 'dart:typed_data';

import 'package:denial_dart_shell/src/models/clipboard_history.dart';
import 'package:denial_dart_shell/src/services/clipboard_history_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'snapshot request and metadata use the bounded binary protocol',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      ByteData? request;
      messenger.setMockMessageHandler(denialClipboardChannel, (message) async {
        request = message;
        return _snapshotPacket(
          revision: 17,
          totalBytes: 321,
          activeId: 42,
          entries: const <_TestEntry>[
            _TestEntry(
              id: 42,
              timestamp: 1_700_000_000_000,
              byteLength: 321,
              width: 640,
              height: 480,
              origin: 1,
              kind: 1,
              flags: 3,
              preview: 'preview',
              appId: 'org.denial.Source',
              title: 'Source window',
              mimeTypes: <String>['image/png', 'text/plain'],
            ),
          ],
        );
      });

      final service = ClipboardHistoryService(messenger: messenger);
      try {
        final snapshot = await service.snapshot(query: 'source');

        expect(snapshot.revision, 17);
        expect(snapshot.totalBytes, 321);
        expect(snapshot.activeId, 42);
        expect(snapshot.paused, isFalse);
        expect(snapshot.locked, isFalse);
        expect(snapshot.entries, hasLength(1));
        final entry = snapshot.entries.single;
        expect(entry.id, 42);
        expect(entry.origin, ClipboardHistoryOrigin.x11);
        expect(entry.kind, ClipboardHistoryContentKind.image);
        expect(entry.pinned, isTrue);
        expect(entry.active, isTrue);
        expect(entry.width, 640);
        expect(entry.height, 480);
        expect(entry.sourceAppId, 'org.denial.Source');
        expect(entry.sourceTitle, 'Source window');
        expect(entry.mimeTypes, <String>['image/png', 'text/plain']);

        final bytes = _bytes(request!);
        expect(bytes.sublist(0, 4), <int>[0x44, 0x43, 0x4c, 0x50]);
        expect(bytes[6], 0);
        final queryLength = ByteData.sublistView(
          bytes,
          8,
          10,
        ).getUint16(0, Endian.little);
        expect(utf8.decode(bytes.sublist(10, 10 + queryLength)), 'source');
      } finally {
        service.dispose();
        messenger.setMockMessageHandler(denialClipboardChannel, null);
      }
    },
  );

  test(
    'read and mutation operations preserve IDs and response revisions',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final commands = <int>[];
      messenger.setMockMessageHandler(denialClipboardChannel, (message) async {
        final bytes = _bytes(message!);
        final command = bytes[6];
        commands.add(command);
        if (command == 1) {
          return _dataPacket(
            itemId: 77,
            mimeType: 'image/png',
            bytes: <int>[0x89, 0x50, 0x4e, 0x47],
          );
        }
        return _ackPacket(100 + command);
      });

      final service = ClipboardHistoryService(messenger: messenger);
      try {
        final data = await service.readData(77, 'image/png');
        expect(data.itemId, 77);
        expect(data.mimeType, 'image/png');
        expect(data.bytes, <int>[0x89, 0x50, 0x4e, 0x47]);

        expect(await service.activate(77), 102);
        expect(await service.setPinned(77, pinned: true), 103);
        expect(await service.delete(77), 104);
        expect(await service.clear(), 105);
        expect(await service.setPaused(paused: true), 106);
        expect(await service.startDrag(77), 107);
        expect(commands, <int>[1, 2, 3, 4, 5, 6, 7]);
      } finally {
        service.dispose();
        messenger.setMockMessageHandler(denialClipboardChannel, null);
      }
    },
  );

  test('native state messages update the broadcast snapshot stream', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final service = ClipboardHistoryService(messenger: messenger);
    final received = <ClipboardHistorySnapshot>[];
    final subscription = service.snapshots.listen(received.add);
    try {
      await messenger.handlePlatformMessage(
        denialClipboardStateChannel,
        _snapshotPacket(
          revision: 9,
          totalBytes: 0,
          activeId: 0,
          paused: true,
          locked: true,
        ),
        null,
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.revision, 9);
      expect(received.single.paused, isTrue);
      expect(received.single.locked, isTrue);
      expect(received.single.entries, isEmpty);
      expect(service.lastSnapshot, same(received.single));
    } finally {
      await subscription.cancel();
      service.dispose();
    }
  });

  test('native errors and hostile packets fail closed', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(
      denialClipboardChannel,
      (_) async => _errorPacket(3, 'locked'),
    );
    final service = ClipboardHistoryService(messenger: messenger);
    try {
      await expectLater(
        service.clear(),
        throwsA(
          isA<ClipboardHistoryException>()
              .having((error) => error.code, 'code', 3)
              .having((error) => error.message, 'message', 'locked'),
        ),
      );
      await expectLater(
        service.readData(0, 'text/plain'),
        throwsA(isA<ClipboardHistoryException>()),
      );
      await expectLater(
        service.snapshot(query: List<String>.filled(257, 'x').join()),
        throwsA(isA<ClipboardHistoryException>()),
      );
      messenger.setMockMessageHandler(
        denialClipboardChannel,
        (_) async => _snapshotPacket(
          revision: 4,
          totalBytes: 1,
          activeId: 0,
          locked: true,
        ),
      );
      await expectLater(
        service.snapshot(),
        throwsA(isA<ClipboardHistoryException>()),
      );
    } finally {
      service.dispose();
      messenger.setMockMessageHandler(denialClipboardChannel, null);
    }
  });
}

ByteData _snapshotPacket({
  required int revision,
  required int totalBytes,
  required int activeId,
  bool paused = false,
  bool locked = false,
  List<_TestEntry> entries = const <_TestEntry>[],
}) {
  final writer = _response(1)
    ..uint64(revision)
    ..uint64(totalBytes)
    ..uint64(activeId)
    ..uint8((paused ? 1 : 0) | (locked ? 2 : 0))
    ..uint16(entries.length);
  for (final entry in entries) {
    writer
      ..uint64(entry.id)
      ..uint64(entry.timestamp)
      ..uint64(entry.byteLength)
      ..uint32(entry.width)
      ..uint32(entry.height)
      ..uint8(entry.origin)
      ..uint8(entry.kind)
      ..uint8(entry.flags)
      ..uint8(entry.mimeTypes.length)
      ..string16(entry.preview)
      ..string16(entry.appId)
      ..string16(entry.title);
    for (final mimeType in entry.mimeTypes) {
      writer.string16(mimeType);
    }
  }
  return writer.data();
}

ByteData _dataPacket({
  required int itemId,
  required String mimeType,
  required List<int> bytes,
}) {
  return (_response(2)
        ..uint64(itemId)
        ..string16(mimeType)
        ..uint64(bytes.length)
        ..bytes(bytes))
      .data();
}

ByteData _ackPacket(int revision) {
  return (_response(0)..uint64(revision)).data();
}

ByteData _errorPacket(int status, String message) {
  return (_Writer()
        ..bytes(const <int>[0x44, 0x43, 0x4c, 0x53])
        ..uint16(1)
        ..uint8(0xff)
        ..uint8(status)
        ..string16(message))
      .data();
}

_Writer _response(int kind) {
  return _Writer()
    ..bytes(const <int>[0x44, 0x43, 0x4c, 0x53])
    ..uint16(1)
    ..uint8(kind)
    ..uint8(0);
}

Uint8List _bytes(ByteData data) {
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

class _TestEntry {
  const _TestEntry({
    required this.id,
    required this.timestamp,
    required this.byteLength,
    required this.width,
    required this.height,
    required this.origin,
    required this.kind,
    required this.flags,
    required this.preview,
    required this.appId,
    required this.title,
    required this.mimeTypes,
  });

  final int id;
  final int timestamp;
  final int byteLength;
  final int width;
  final int height;
  final int origin;
  final int kind;
  final int flags;
  final String preview;
  final String appId;
  final String title;
  final List<String> mimeTypes;
}

class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) => _builder.add(value);

  void uint8(int value) => _builder.add(<int>[value]);

  void uint16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void uint32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void uint64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void string16(String value) {
    final bytes = utf8.encode(value);
    uint16(bytes.length);
    this.bytes(bytes);
  }

  ByteData data() => ByteData.sublistView(_builder.takeBytes());
}
