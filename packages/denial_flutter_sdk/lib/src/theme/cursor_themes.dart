import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

/// The saved cursor size is in logical pixels, as `XCURSOR_SIZE` is for apps:
/// on each display the cursor is this size times the display's scale, drawn
/// from the smallest rendition at least that large.
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

/// A larger rendering of a role's artwork, drawn for its own size rather
/// than scaled up. Its frames live in `SIZE/` inside the role directory.
@immutable
class ShellCursorRenditionData {
  const ShellCursorRenditionData(this.extent, this.hotspot);

  /// Longest edge in pixels, and the name of its directory.
  final int extent;
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
    this.renditions = const <ShellCursorRenditionData>[],
  }) : assert(frameCount > 0);

  final String assetDirectory;

  /// Native artwork dimensions used to preserve shape and hotspot ratios.
  final Size size;
  final Offset hotspot;

  /// Multiple frames and a positive duration opt into renderer animation.
  final int frameCount;
  final Duration frameDuration;
  final List<ShellCursorFrameData> frames;

  /// Larger renderings, smallest first. Only for numbered frames: explicit
  /// [frames] come in one size.
  final List<ShellCursorRenditionData> renditions;

  double get nativeExtent =>
      size.width > size.height ? size.width : size.height;

  /// The smallest rendition whose longest edge reaches [pixels], the largest
  /// if none does, or null when the native artwork is large enough.
  ShellCursorRenditionData? renditionFor(double pixels) {
    // Half a pixel of slack keeps a 32 px cursor at a 1.0000001 scale on
    // the 32 px artwork.
    if (frames.isNotEmpty ||
        renditions.isEmpty ||
        pixels <= nativeExtent + 0.5) {
      return null;
    }
    for (final rendition in renditions) {
      if (pixels <= rendition.extent + 0.5) {
        return rendition;
      }
    }
    return renditions.last;
  }

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

  String relativeFramePath(int frame, [ShellCursorRenditionData? rendition]) {
    if (frames.isNotEmpty) {
      return frames[frame % frames.length].path;
    }
    final frameName = (frame % frameCount).toString().padLeft(2, '0');
    if (rendition != null) {
      return '$assetDirectory/${rendition.extent}/$frameName.png';
    }
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

  String assetPath(
    ShellCursorKind kind,
    int frame, [
    ShellCursorRenditionData? rendition,
  ]) {
    final root = assetRoot;
    assert(root != null, 'The vector cursor has no asset path.');
    final role = roleFor(kind);
    return '$root/${role.relativeFramePath(frame, rendition)}';
  }

  ImageProvider<Object>? imageProvider(
    ShellCursorKind kind,
    int frame, [
    ShellCursorRenditionData? rendition,
  ]) {
    final role = roleFor(kind);
    final relativePath = role.relativeFramePath(frame, rendition);
    if (assetRoot case final root?) {
      return AssetImage('$root/$relativePath');
    }
    if (fileRoot case final root?) {
      return FileImage(File(p.join(root, relativePath)));
    }
    return null;
  }

  /// Every role's native frames.
  Iterable<ImageProvider<Object>> get imageProviders => imageProvidersFor(0);

  /// The frames of the rendition a cursor [pixels] wide draws from.
  Iterable<ImageProvider<Object>> imageProvidersFor(double pixels) sync* {
    if (!usesImageFrames) {
      return;
    }
    for (final kind in ShellCursorKind.values) {
      final role = roleFor(kind);
      final rendition = role.renditionFor(pixels);
      for (var frame = 0; frame < role.effectiveFrameCount; frame += 1) {
        yield imageProvider(kind, frame, rendition)!;
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
        for (final rendition in role.renditions) {
          yield assetPath(kind, frame, rendition);
        }
      }
    }
  }
}

abstract final class ShellCursorThemes {
  static const _bibataSize = Size(32, 32);

  /// Bibata's 48, 64 and 96 px renderings of a cursor centred on its canvas.
  static const _bibataCentred = <ShellCursorRenditionData>[
    ShellCursorRenditionData(48, Offset(24, 24)),
    ShellCursorRenditionData(64, Offset(32, 32)),
    ShellCursorRenditionData(96, Offset(48, 48)),
  ];

  static const _bibataNormal = ShellCursorRoleData(
    assetDirectory: 'normal',
    size: _bibataSize,
    hotspot: Offset(6, 2),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(10, 3)),
      ShellCursorRenditionData(64, Offset(13, 4)),
      ShellCursorRenditionData(96, Offset(20, 6)),
    ],
  );
  static const _bibataHelp = ShellCursorRoleData(
    assetDirectory: 'help',
    size: _bibataSize,
    hotspot: Offset(5, 10),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(7, 16)),
      ShellCursorRenditionData(64, Offset(10, 21)),
      ShellCursorRenditionData(96, Offset(15, 32)),
    ],
  );
  static const _bibataWorking = ShellCursorRoleData(
    assetDirectory: 'working',
    size: _bibataSize,
    hotspot: Offset(6, 2),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(10, 3)),
      ShellCursorRenditionData(64, Offset(13, 4)),
      ShellCursorRenditionData(96, Offset(20, 6)),
    ],
  );
  static const _bibataText = ShellCursorRoleData(
    assetDirectory: 'text',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataLink = ShellCursorRoleData(
    assetDirectory: 'link',
    size: _bibataSize,
    hotspot: Offset(14, 2),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(21, 3)),
      ShellCursorRenditionData(64, Offset(28, 4)),
      ShellCursorRenditionData(96, Offset(42, 6)),
    ],
  );
  static const _bibataBusy = ShellCursorRoleData(
    assetDirectory: 'busy',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataPrecision = ShellCursorRoleData(
    assetDirectory: 'precision',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataHandwriting = ShellCursorRoleData(
    assetDirectory: 'handwriting',
    size: _bibataSize,
    hotspot: Offset(5, 26),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(8, 39)),
      ShellCursorRenditionData(64, Offset(11, 52)),
      ShellCursorRenditionData(96, Offset(17, 79)),
    ],
  );
  static const _bibataUnavailable = ShellCursorRoleData(
    assetDirectory: 'unavailable',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataVerticalResize = ShellCursorRoleData(
    assetDirectory: 'vertical_resize',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataHorizontalResize = ShellCursorRoleData(
    assetDirectory: 'horizontal_resize',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataDiagonalNwSeResize = ShellCursorRoleData(
    assetDirectory: 'diagonal_nwse',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataDiagonalNeSwResize = ShellCursorRoleData(
    assetDirectory: 'diagonal_nesw',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataMove = ShellCursorRoleData(
    assetDirectory: 'move',
    size: _bibataSize,
    hotspot: Offset(16, 16),
    renditions: _bibataCentred,
  );
  static const _bibataAlternate = ShellCursorRoleData(
    assetDirectory: 'alternate',
    size: _bibataSize,
    hotspot: Offset(12, 8),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(18, 12)),
      ShellCursorRenditionData(64, Offset(25, 16)),
      ShellCursorRenditionData(96, Offset(37, 24)),
    ],
  );
  static const _bibataPerson = ShellCursorRoleData(
    assetDirectory: 'person',
    size: _bibataSize,
    hotspot: Offset(4, 1),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(6, 2)),
      ShellCursorRenditionData(64, Offset(9, 2)),
      ShellCursorRenditionData(96, Offset(13, 4)),
    ],
  );
  static const _bibataPin = ShellCursorRoleData(
    assetDirectory: 'pin',
    size: _bibataSize,
    hotspot: Offset(4, 1),
    renditions: <ShellCursorRenditionData>[
      ShellCursorRenditionData(48, Offset(6, 2)),
      ShellCursorRenditionData(64, Offset(9, 2)),
      ShellCursorRenditionData(96, Offset(13, 4)),
    ],
  );

  static const bibataModernIce = ShellCursorThemeData(
    id: 'bibata_modern_ice',
    label: 'Bibata Modern Ice',
    author: 'Abdulkaiz Khatri',
    assetRoot: 'packages/denial_flutter_sdk/assets/cursors/bibata_modern_ice',
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
