import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

/// The saved cursor size is a physical-pixel target. Cursor artwork is drawn
/// at this size on every output, independent of that output's display scale.
const double shellCursorMinimumSize = 16;
const double shellCursorDefaultSize = 32;
const double shellCursorMaximumSize = 64;

enum ShellCursorKind {
  normal,
  help,
  working,
  text,
  link,
  busy,
  precision,
  handwriting,
  unavailable,
  verticalResize,
  horizontalResize,
  diagonalNwSeResize,
  diagonalNeSwResize,
  move,
  alternate,
  person,
  pin,
}

@immutable
class ShellCursorFrameData {
  const ShellCursorFrameData({
    required this.path,
    required this.duration,
    required this.hotspot,
  });

  /// Relative to the role directory for bundled themes and to the imported
  /// theme root for locally installed themes.
  final String path;
  final Duration duration;
  final Offset hotspot;
}

@immutable
class ShellCursorRoleData {
  const ShellCursorRoleData({
    required this.assetDirectory,
    required this.size,
    required this.hotspot,
    this.frameCount = 1,
    this.frameDuration = Duration.zero,
    this.frames = const <ShellCursorFrameData>[],
  }) : assert(frameCount > 0);

  final String assetDirectory;

  /// Native artwork dimensions used to preserve shape and hotspot ratios.
  final Size size;
  final Offset hotspot;

  /// Multiple frames and a positive duration opt into renderer animation.
  final int frameCount;
  final Duration frameDuration;
  final List<ShellCursorFrameData> frames;

  int get effectiveFrameCount => frames.isEmpty ? frameCount : frames.length;

  bool get isAnimated =>
      effectiveFrameCount > 1 &&
      List<Duration>.generate(
        effectiveFrameCount,
        frameDurationAt,
        growable: false,
      ).any((duration) => duration.inMicroseconds > 0);

  Duration frameDurationAt(int frame) {
    if (frames.isNotEmpty) {
      return frames[frame % frames.length].duration;
    }
    return frameDuration;
  }

  Offset hotspotAt(int frame) {
    if (frames.isNotEmpty) {
      return frames[frame % frames.length].hotspot;
    }
    return hotspot;
  }

  String relativeFramePath(int frame) {
    if (frames.isNotEmpty) {
      return frames[frame % frames.length].path;
    }
    final frameName = (frame % frameCount).toString().padLeft(2, '0');
    return '$assetDirectory/$frameName.png';
  }
}

@immutable
class ShellCursorThemeData {
  const ShellCursorThemeData({
    required this.id,
    required this.label,
    required this.author,
    required this.assetRoot,
    this.fileRoot,
    required this.roles,
  });

  final String id;
  final String label;
  final String author;

  /// Bundled frame root. Imported themes instead use [fileRoot].
  final String? assetRoot;
  final String? fileRoot;
  final Map<ShellCursorKind, ShellCursorRoleData> roles;

  bool get usesImageFrames => assetRoot != null || fileRoot != null;
  bool get isImported => fileRoot != null;

  ShellCursorRoleData roleFor(ShellCursorKind kind) {
    return roles[kind] ?? roles[ShellCursorKind.normal]!;
  }

  String assetPath(ShellCursorKind kind, int frame) {
    final root = assetRoot;
    assert(root != null, 'The vector cursor has no asset path.');
    final role = roleFor(kind);
    return '$root/${role.relativeFramePath(frame)}';
  }

  ImageProvider<Object>? imageProvider(ShellCursorKind kind, int frame) {
    final role = roleFor(kind);
    final relativePath = role.relativeFramePath(frame);
    if (assetRoot case final root?) {
      return AssetImage('$root/$relativePath');
    }
    if (fileRoot case final root?) {
      return FileImage(File(p.join(root, relativePath)));
    }
    return null;
  }

  Iterable<ImageProvider<Object>> get imageProviders sync* {
    if (!usesImageFrames) {
      return;
    }
    for (final kind in ShellCursorKind.values) {
      final role = roleFor(kind);
      for (var frame = 0; frame < role.effectiveFrameCount; frame += 1) {
        yield imageProvider(kind, frame)!;
      }
    }
  }

  /// Bundled compatibility view used by asset validation and older tests.
  Iterable<String> get assetPaths sync* {
    if (assetRoot == null) {
      return;
    }
    for (final kind in ShellCursorKind.values) {
      final role = roleFor(kind);
      for (var frame = 0; frame < role.effectiveFrameCount; frame += 1) {
        yield assetPath(kind, frame);
      }
    }
  }
}

abstract final class ShellCursorThemes {
  static const _bibataSize = Size(32, 32);

  static const _bibataNormal = ShellCursorRoleData(
    assetDirectory: 'normal',
    size: _bibataSize,
    hotspot: Offset(6, 2),
  );
  static const _bibataHelp = ShellCursorRoleData(
    assetDirectory: 'help',
    size: _bibataSize,
    hotspot: Offset(5, 10),
  );
  static const _bibataWorking = ShellCursorRoleData(
    assetDirectory: 'working',
    size: _bibataSize,
    hotspot: Offset(6, 2),
  );
  static const _bibataText = ShellCursorRoleData(
    assetDirectory: 'text',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataLink = ShellCursorRoleData(
    assetDirectory: 'link',
    size: _bibataSize,
    hotspot: Offset(14, 2),
  );
  static const _bibataBusy = ShellCursorRoleData(
    assetDirectory: 'busy',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataPrecision = ShellCursorRoleData(
    assetDirectory: 'precision',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataHandwriting = ShellCursorRoleData(
    assetDirectory: 'handwriting',
    size: _bibataSize,
    hotspot: Offset(5, 26),
  );
  static const _bibataUnavailable = ShellCursorRoleData(
    assetDirectory: 'unavailable',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataVerticalResize = ShellCursorRoleData(
    assetDirectory: 'vertical_resize',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataHorizontalResize = ShellCursorRoleData(
    assetDirectory: 'horizontal_resize',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataDiagonalNwSeResize = ShellCursorRoleData(
    assetDirectory: 'diagonal_nwse',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataDiagonalNeSwResize = ShellCursorRoleData(
    assetDirectory: 'diagonal_nesw',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataMove = ShellCursorRoleData(
    assetDirectory: 'move',
    size: _bibataSize,
    hotspot: Offset(16, 16),
  );
  static const _bibataAlternate = ShellCursorRoleData(
    assetDirectory: 'alternate',
    size: _bibataSize,
    hotspot: Offset(12, 8),
  );
  static const _bibataPerson = ShellCursorRoleData(
    assetDirectory: 'person',
    size: _bibataSize,
    hotspot: Offset(4, 1),
  );
  static const _bibataPin = ShellCursorRoleData(
    assetDirectory: 'pin',
    size: _bibataSize,
    hotspot: Offset(4, 1),
  );

  static const bibataModernIce = ShellCursorThemeData(
    id: 'bibata_modern_ice',
    label: 'Bibata Modern Ice',
    author: 'Abdulkaiz Khatri',
    assetRoot: 'assets/cursors/bibata_modern_ice',
    roles: <ShellCursorKind, ShellCursorRoleData>{
      ShellCursorKind.normal: _bibataNormal,
      ShellCursorKind.help: _bibataHelp,
      ShellCursorKind.working: _bibataWorking,
      ShellCursorKind.text: _bibataText,
      ShellCursorKind.link: _bibataLink,
      ShellCursorKind.busy: _bibataBusy,
      ShellCursorKind.precision: _bibataPrecision,
      ShellCursorKind.handwriting: _bibataHandwriting,
      ShellCursorKind.unavailable: _bibataUnavailable,
      ShellCursorKind.verticalResize: _bibataVerticalResize,
      ShellCursorKind.horizontalResize: _bibataHorizontalResize,
      ShellCursorKind.diagonalNwSeResize: _bibataDiagonalNwSeResize,
      ShellCursorKind.diagonalNeSwResize: _bibataDiagonalNeSwResize,
      ShellCursorKind.move: _bibataMove,
      ShellCursorKind.alternate: _bibataAlternate,
      ShellCursorKind.person: _bibataPerson,
      ShellCursorKind.pin: _bibataPin,
    },
  );

  static const List<ShellCursorThemeData> all = <ShellCursorThemeData>[
    bibataModernIce,
  ];

  static ShellCursorThemeData? find(String id) {
    for (final theme in all) {
      if (theme.id == id) {
        return theme;
      }
    }
    return null;
  }
}
