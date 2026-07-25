import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clipboard_history.dart';

const String denialClipboardChannel = 'denial/clipboard';
const String denialClipboardStateChannel = 'denial/clipboard_state';

final clipboardHistoryServiceProvider = Provider<ClipboardHistoryService>((
  ref,
) {
  final service = ClipboardHistoryService();
  ref.onDispose(service.dispose);
  return service;
});

const List<int> _requestMagic = <int>[0x44, 0x43, 0x4c, 0x50]; // DCLP
const List<int> _responseMagic = <int>[0x44, 0x43, 0x4c, 0x53]; // DCLS
const int _protocolVersion = 1;

const int _snapshotCommand = 0;
const int _readCommand = 1;
const int _activateCommand = 2;
const int _setPinnedCommand = 3;
const int _deleteCommand = 4;
const int _clearCommand = 5;
const int _setPausedCommand = 6;
const int _startDragCommand = 7;

const int _ackResponse = 0;
const int _snapshotResponse = 1;
const int _dataResponse = 2;
const int _errorResponse = 0xff;

const int _snapshotPaused = 1 << 0;
const int _snapshotLocked = 1 << 1;
const int _entryPinned = 1 << 0;
const int _entryActive = 1 << 1;

const int _maxRequestBytes = 4096;
const int _maxQueryBytes = 256;
const int _maxMimeBytes = 256;
const int _maxHistoryItems = 100;
const int _maxRepresentations = 4;
const int _maxPreviewBytes = 1024;
const int _maxSourceAppIdBytes = 512;
const int _maxSourceTitleBytes = 1024;
const int _maxDataBytes = 16 * 1024 * 1024;

class ClipboardHistoryService {
  ClipboardHistoryService({BinaryMessenger? messenger})
    : _messenger =
          messenger ?? ServicesBinding.instance.defaultBinaryMessenger {
    _messenger.setMessageHandler(
      denialClipboardStateChannel,
      _handleStateMessage,
    );
  }

  final BinaryMessenger _messenger;
  final StreamController<ClipboardHistorySnapshot> _snapshots =
      StreamController<ClipboardHistorySnapshot>.broadcast(sync: true);
  ClipboardHistorySnapshot? _lastSnapshot;
  bool _disposed = false;

  Stream<ClipboardHistorySnapshot> get snapshots => _snapshots.stream;
  ClipboardHistorySnapshot? get lastSnapshot => _lastSnapshot;

  Future<ClipboardHistorySnapshot> snapshot({String query = ''}) async {
    final queryBytes = utf8.encode(query);
    if (queryBytes.length > _maxQueryBytes || queryBytes.contains(0)) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard search query is invalid or too long',
      );
    }
    final writer = _request(_snapshotCommand)..string16(query);
    final response = await _send(writer);
    return _decodeSnapshot(response);
  }

  Future<ClipboardHistoryData> readData(int itemId, String mimeType) async {
    _validateItemId(itemId);
    final mimeBytes = utf8.encode(mimeType);
    if (mimeBytes.isEmpty ||
        mimeBytes.length > _maxMimeBytes ||
        mimeBytes.contains(0)) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard MIME type is invalid',
      );
    }
    final writer = _request(_readCommand)
      ..uint64(itemId)
      ..string16(mimeType);
    final data = _decodeData(await _send(writer));
    if (data.itemId != itemId || data.mimeType != mimeType) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard data response did not match its request',
      );
    }
    return data;
  }

  Future<int> activate(int itemId) => _itemCommand(_activateCommand, itemId);

  Future<int> setPinned(int itemId, {required bool pinned}) async {
    _validateItemId(itemId);
    final writer = _request(_setPinnedCommand)
      ..uint64(itemId)
      ..uint8(pinned ? 1 : 0);
    return _decodeAck(await _send(writer));
  }

  Future<int> delete(int itemId) => _itemCommand(_deleteCommand, itemId);

  Future<int> clear() async {
    return _decodeAck(await _send(_request(_clearCommand)));
  }

  Future<int> setPaused({required bool paused}) async {
    final writer = _request(_setPausedCommand)..uint8(paused ? 1 : 0);
    return _decodeAck(await _send(writer));
  }

  /// Starts a compositor-owned copy drag from the current Flutter pointer
  /// press. The native source keeps every retained MIME representation, so
  /// Wayland and Xwayland targets can negotiate text, files, or image bytes.
  Future<int> startDrag(int itemId) => _itemCommand(_startDragCommand, itemId);

  Future<void> setText(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _messenger.setMessageHandler(denialClipboardStateChannel, null);
    unawaited(_snapshots.close());
  }

  Future<int> _itemCommand(int command, int itemId) async {
    _validateItemId(itemId);
    final writer = _request(command)..uint64(itemId);
    return _decodeAck(await _send(writer));
  }

  Future<ByteData> _send(_PacketWriter writer) async {
    if (_disposed) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard history service is disposed',
      );
    }
    final bytes = writer.takeBytes();
    if (bytes.length > _maxRequestBytes) {
      throw const ClipboardHistoryException(
        4,
        'Clipboard request exceeds its native limit',
      );
    }
    final pending = _messenger.send(
      denialClipboardChannel,
      ByteData.sublistView(bytes),
    );
    if (pending == null) {
      throw const ClipboardHistoryException(
        1,
        'Clipboard platform channel is unavailable',
      );
    }
    final response = await pending.timeout(const Duration(seconds: 2));
    if (response == null) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard returned no response',
      );
    }
    return response;
  }

  Future<ByteData?> _handleStateMessage(ByteData? message) async {
    if (_disposed || message == null) {
      return null;
    }
    try {
      final snapshot = _decodeSnapshot(message);
      _lastSnapshot = snapshot;
      _snapshots.add(snapshot);
    } on Object catch (error, stackTrace) {
      _snapshots.addError(error, stackTrace);
    }
    return null;
  }
}

_PacketWriter _request(int command) {
  return _PacketWriter()
    ..bytes(_requestMagic)
    ..uint16(_protocolVersion)
    ..uint8(command)
    ..uint8(0);
}

void _validateItemId(int itemId) {
  if (itemId <= 0) {
    throw const ClipboardHistoryException(
      1,
      'Clipboard item ID must be positive',
    );
  }
}

int _decodeAck(ByteData packet) {
  final reader = _response(packet, _ackResponse);
  final revision = reader.uint64();
  reader.expectEnd();
  return revision;
}

ClipboardHistoryData _decodeData(ByteData packet) {
  final reader = _response(packet, _dataResponse);
  final itemId = reader.nonzeroUint64();
  final mimeType = reader.string16(_maxMimeBytes);
  final length = reader.uint64();
  if (length > _maxDataBytes || length > reader.remaining) {
    throw const ClipboardHistoryException(
      4,
      'Native clipboard data exceeds its limit',
    );
  }
  final bytes = reader.bytes(length);
  reader.expectEnd();
  return ClipboardHistoryData(itemId: itemId, mimeType: mimeType, bytes: bytes);
}

ClipboardHistorySnapshot _decodeSnapshot(ByteData packet) {
  final reader = _response(packet, _snapshotResponse);
  final revision = reader.uint64();
  final totalBytes = reader.uint64();
  final rawActiveId = reader.uint64();
  final flags = reader.uint8();
  if (flags & ~(_snapshotPaused | _snapshotLocked) != 0) {
    throw const ClipboardHistoryException(
      1,
      'Native clipboard snapshot has unknown flags',
    );
  }
  final count = reader.uint16();
  if (count > _maxHistoryItems) {
    throw const ClipboardHistoryException(
      4,
      'Native clipboard snapshot has too many entries',
    );
  }
  final entries = <ClipboardHistoryEntry>[];
  for (var index = 0; index < count; index += 1) {
    final id = reader.nonzeroUint64();
    final capturedUnixMs = reader.uint64();
    final byteLength = reader.uint64();
    final width = reader.uint32();
    final height = reader.uint32();
    final originIndex = reader.uint8();
    final kindIndex = reader.uint8();
    final entryFlags = reader.uint8();
    final mimeCount = reader.uint8();
    if (originIndex >= ClipboardHistoryOrigin.values.length ||
        kindIndex >= ClipboardHistoryContentKind.values.length ||
        entryFlags & ~(_entryPinned | _entryActive) != 0 ||
        mimeCount == 0 ||
        mimeCount > _maxRepresentations) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard entry metadata is invalid',
      );
    }
    final preview = reader.string16(_maxPreviewBytes);
    final sourceAppId = reader.string16(_maxSourceAppIdBytes);
    final sourceTitle = reader.string16(_maxSourceTitleBytes);
    final mimeTypes = List<String>.generate(
      mimeCount,
      (_) => reader.string16(_maxMimeBytes),
      growable: false,
    );
    entries.add(
      ClipboardHistoryEntry(
        id: id,
        capturedAt: DateTime.fromMillisecondsSinceEpoch(
          capturedUnixMs,
          isUtc: true,
        ),
        byteLength: byteLength,
        width: width,
        height: height,
        origin: ClipboardHistoryOrigin.values[originIndex],
        kind: ClipboardHistoryContentKind.values[kindIndex],
        pinned: entryFlags & _entryPinned != 0,
        active: entryFlags & _entryActive != 0,
        preview: preview,
        sourceAppId: sourceAppId,
        sourceTitle: sourceTitle,
        mimeTypes: List<String>.unmodifiable(mimeTypes),
      ),
    );
  }
  reader.expectEnd();
  final locked = flags & _snapshotLocked != 0;
  if (locked && (entries.isNotEmpty || totalBytes != 0 || rawActiveId != 0)) {
    throw const ClipboardHistoryException(
      1,
      'Locked clipboard snapshot was not redacted',
    );
  }
  return ClipboardHistorySnapshot(
    revision: revision,
    totalBytes: totalBytes,
    activeId: rawActiveId == 0 ? null : rawActiveId,
    paused: flags & _snapshotPaused != 0,
    locked: locked,
    entries: List<ClipboardHistoryEntry>.unmodifiable(entries),
  );
}

_PacketReader _response(ByteData packet, int expectedKind) {
  final reader = _PacketReader(packet);
  if (!reader.consumeMagic(_responseMagic) ||
      reader.uint16() != _protocolVersion) {
    throw const ClipboardHistoryException(
      1,
      'Native clipboard response has an invalid envelope',
    );
  }
  final kind = reader.uint8();
  final status = reader.uint8();
  if (kind == _errorResponse) {
    final message = reader.string16(1024);
    reader.expectEnd();
    throw ClipboardHistoryException(status, message);
  }
  if (status != 0 || kind != expectedKind) {
    throw const ClipboardHistoryException(
      1,
      'Native clipboard response has an unexpected type',
    );
  }
  return reader;
}

class _PacketWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) {
    _builder.add(value);
  }

  void uint8(int value) {
    _builder.add(<int>[value]);
  }

  void uint16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void uint64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void string16(String value) {
    final encoded = utf8.encode(value);
    if (encoded.length > 0xffff) {
      throw const ClipboardHistoryException(
        4,
        'Clipboard string exceeds its wire limit',
      );
    }
    uint16(encoded.length);
    bytes(encoded);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

class _PacketReader {
  _PacketReader(ByteData data)
    : _bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

  final Uint8List _bytes;
  int _offset = 0;

  int get remaining => _bytes.length - _offset;

  bool consumeMagic(List<int> expected) {
    if (remaining < expected.length) {
      return false;
    }
    for (var index = 0; index < expected.length; index += 1) {
      if (_bytes[_offset + index] != expected[index]) {
        return false;
      }
    }
    _offset += expected.length;
    return true;
  }

  int uint8() {
    _require(1);
    return _bytes[_offset++];
  }

  int uint16() {
    _require(2);
    final value = ByteData.sublistView(
      _bytes,
      _offset,
      _offset + 2,
    ).getUint16(0, Endian.little);
    _offset += 2;
    return value;
  }

  int uint32() {
    _require(4);
    final value = ByteData.sublistView(
      _bytes,
      _offset,
      _offset + 4,
    ).getUint32(0, Endian.little);
    _offset += 4;
    return value;
  }

  int uint64() {
    _require(8);
    final value = ByteData.sublistView(
      _bytes,
      _offset,
      _offset + 8,
    ).getUint64(0, Endian.little);
    _offset += 8;
    return value;
  }

  int nonzeroUint64() {
    final value = uint64();
    if (value == 0) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard returned a zero item ID',
      );
    }
    return value;
  }

  String string16(int maximumBytes) {
    final length = uint16();
    if (length > maximumBytes) {
      throw const ClipboardHistoryException(
        4,
        'Native clipboard string exceeds its limit',
      );
    }
    final value = utf8.decode(_take(length), allowMalformed: false);
    if (value.codeUnits.contains(0)) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard string contains NUL',
      );
    }
    return value;
  }

  Uint8List bytes(int length) {
    return Uint8List.fromList(_take(length));
  }

  void expectEnd() {
    if (remaining != 0) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard packet has trailing data',
      );
    }
  }

  Uint8List _take(int length) {
    _require(length);
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  void _require(int length) {
    if (length < 0 || length > remaining) {
      throw const ClipboardHistoryException(
        1,
        'Native clipboard packet is truncated',
      );
    }
  }
}
