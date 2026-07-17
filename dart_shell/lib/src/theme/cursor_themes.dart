import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

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
class ShellCursorRoleData {
  const ShellCursorRoleData({
    required this.assetDirectory,
    required this.size,
    required this.hotspot,
    required this.frameCount,
    required this.frameDuration,
  });

  final String assetDirectory;
  final Size size;
  final Offset hotspot;
  final int frameCount;
  final Duration frameDuration;
}

@immutable
class ShellCursorThemeData {
  const ShellCursorThemeData({
    required this.id,
    required this.label,
    required this.author,
    required this.assetRoot,
    required this.roles,
  });

  final String id;
  final String label;
  final String author;

  /// Null only for the shell's built-in vector fallback.
  final String? assetRoot;
  final Map<ShellCursorKind, ShellCursorRoleData> roles;

  bool get usesAssetFrames => assetRoot != null;

  ShellCursorRoleData roleFor(ShellCursorKind kind) {
    return roles[kind] ?? roles[ShellCursorKind.normal]!;
  }

  String assetPath(ShellCursorKind kind, int frame) {
    final root = assetRoot;
    assert(root != null, 'The vector cursor has no asset path.');
    final role = roleFor(kind);
    final frameName = frame.toString().padLeft(2, '0');
    return '$root/${role.assetDirectory}/$frameName.png';
  }

  Iterable<String> get assetPaths sync* {
    if (!usesAssetFrames) {
      return;
    }
    for (final kind in ShellCursorKind.values) {
      final role = roleFor(kind);
      for (var frame = 0; frame < role.frameCount; frame += 1) {
        yield assetPath(kind, frame);
      }
    }
  }
}

abstract final class ShellCursorThemes {
  static const standard = ShellCursorThemeData(
    id: 'standard',
    label: 'Denia Standard',
    author: 'Denia',
    assetRoot: null,
    roles: <ShellCursorKind, ShellCursorRoleData>{},
  );

  static const _yangyangFrameDuration = Duration(microseconds: 83333);
  static const _yangyangSize = Size(32, 32);

  static const _yangyangNormal = ShellCursorRoleData(
    assetDirectory: 'normal',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangHelp = ShellCursorRoleData(
    assetDirectory: 'help',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangWorking = ShellCursorRoleData(
    assetDirectory: 'working',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangText = ShellCursorRoleData(
    assetDirectory: 'text',
    size: _yangyangSize,
    hotspot: Offset(4, 9),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangLink = ShellCursorRoleData(
    assetDirectory: 'link',
    size: _yangyangSize,
    hotspot: Offset(4, 0),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangBusy = ShellCursorRoleData(
    assetDirectory: 'busy',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangPrecision = ShellCursorRoleData(
    assetDirectory: 'precision',
    size: _yangyangSize,
    hotspot: Offset(5, 6),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangHandwriting = ShellCursorRoleData(
    assetDirectory: 'handwriting',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangUnavailable = ShellCursorRoleData(
    assetDirectory: 'unavailable',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangVerticalResize = ShellCursorRoleData(
    assetDirectory: 'vertical_resize',
    size: _yangyangSize,
    hotspot: Offset(15, 15),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangHorizontalResize = ShellCursorRoleData(
    assetDirectory: 'horizontal_resize',
    size: _yangyangSize,
    hotspot: Offset(15, 15),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangDiagonalNwSeResize = ShellCursorRoleData(
    assetDirectory: 'diagonal_nwse',
    size: _yangyangSize,
    hotspot: Offset(15, 15),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangDiagonalNeSwResize = ShellCursorRoleData(
    assetDirectory: 'diagonal_nesw',
    size: _yangyangSize,
    hotspot: Offset(15, 15),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangMove = ShellCursorRoleData(
    assetDirectory: 'move',
    size: _yangyangSize,
    hotspot: Offset(15, 15),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangAlternate = ShellCursorRoleData(
    assetDirectory: 'alternate',
    size: _yangyangSize,
    hotspot: Offset(4, 0),
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangPerson = ShellCursorRoleData(
    assetDirectory: 'person',
    size: Size(32, 33),
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );
  static const _yangyangPin = ShellCursorRoleData(
    assetDirectory: 'pin',
    size: _yangyangSize,
    hotspot: Offset.zero,
    frameCount: 12,
    frameDuration: _yangyangFrameDuration,
  );

  static const yangyangXuanling = ShellCursorThemeData(
    id: 'yangyang_xuanling',
    label: 'Yangyang Xuanling',
    author: 'BLZ',
    assetRoot: 'assets/cursors/yangyang_xuanling',
    roles: <ShellCursorKind, ShellCursorRoleData>{
      ShellCursorKind.normal: _yangyangNormal,
      ShellCursorKind.help: _yangyangHelp,
      ShellCursorKind.working: _yangyangWorking,
      ShellCursorKind.text: _yangyangText,
      ShellCursorKind.link: _yangyangLink,
      ShellCursorKind.busy: _yangyangBusy,
      ShellCursorKind.precision: _yangyangPrecision,
      ShellCursorKind.handwriting: _yangyangHandwriting,
      ShellCursorKind.unavailable: _yangyangUnavailable,
      ShellCursorKind.verticalResize: _yangyangVerticalResize,
      ShellCursorKind.horizontalResize: _yangyangHorizontalResize,
      ShellCursorKind.diagonalNwSeResize: _yangyangDiagonalNwSeResize,
      ShellCursorKind.diagonalNeSwResize: _yangyangDiagonalNeSwResize,
      ShellCursorKind.move: _yangyangMove,
      ShellCursorKind.alternate: _yangyangAlternate,
      ShellCursorKind.person: _yangyangPerson,
      ShellCursorKind.pin: _yangyangPin,
    },
  );

  static const List<ShellCursorThemeData> all = <ShellCursorThemeData>[
    standard,
    yangyangXuanling,
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
