import 'dart:typed_data';

enum ClipboardHistoryOrigin { wayland, x11, flutter }

enum ClipboardHistoryContentKind { text, image }

class ClipboardHistoryEntry {
  const ClipboardHistoryEntry({
    required this.id,
    required this.capturedAt,
    required this.byteLength,
    required this.width,
    required this.height,
    required this.origin,
    required this.kind,
    required this.pinned,
    required this.active,
    required this.preview,
    required this.sourceAppId,
    required this.sourceTitle,
    required this.mimeTypes,
  });

  final int id;
  final DateTime capturedAt;
  final int byteLength;
  final int width;
  final int height;
  final ClipboardHistoryOrigin origin;
  final ClipboardHistoryContentKind kind;
  final bool pinned;
  final bool active;
  final String preview;
  final String sourceAppId;
  final String sourceTitle;
  final List<String> mimeTypes;

  String get primaryMimeType => mimeTypes.first;

  bool get isImage => kind == ClipboardHistoryContentKind.image;
}

class ClipboardHistorySnapshot {
  const ClipboardHistorySnapshot({
    required this.revision,
    required this.totalBytes,
    required this.activeId,
    required this.paused,
    required this.locked,
    required this.entries,
  });

  final int revision;
  final int totalBytes;
  final int? activeId;
  final bool paused;
  final bool locked;
  final List<ClipboardHistoryEntry> entries;
}

class ClipboardHistoryData {
  const ClipboardHistoryData({
    required this.itemId,
    required this.mimeType,
    required this.bytes,
  });

  final int itemId;
  final String mimeType;
  final Uint8List bytes;
}

class ClipboardHistoryException implements Exception {
  const ClipboardHistoryException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'ClipboardHistoryException($code, $message)';
}
