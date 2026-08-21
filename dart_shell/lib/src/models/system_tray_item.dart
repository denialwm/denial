import 'package:flutter/foundation.dart';

enum SystemTrayItemSource { statusNotifier, xEmbed }

enum SystemTrayStatus { passive, active, needsAttention }

enum SystemTrayAction { activate, secondaryActivate, contextMenu }

enum SystemTrayMenuToggleType { none, checkmark, radio }

@immutable
class SystemTrayMenuEntry {
  const SystemTrayMenuEntry({
    required this.id,
    required this.label,
    required this.enabled,
    required this.visible,
    required this.separator,
    required this.toggleType,
    required this.toggleState,
    required this.destructive,
    required this.children,
  });

  final int id;
  final String label;
  final bool enabled;
  final bool visible;
  final bool separator;
  final SystemTrayMenuToggleType toggleType;
  final int toggleState;
  final bool destructive;
  final List<SystemTrayMenuEntry> children;
}

@immutable
class SystemTrayIconPixmap {
  const SystemTrayIconPixmap({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;

  /// Premultiplied RGBA8888 pixels in row-major order.
  final Uint8List rgba;

  @override
  bool operator ==(Object other) {
    return other is SystemTrayIconPixmap &&
        other.width == width &&
        other.height == height &&
        listEquals(other.rgba, rgba);
  }

  @override
  int get hashCode => Object.hash(width, height, Object.hashAll(rgba));
}

@immutable
class SystemTrayItem {
  const SystemTrayItem({
    required this.id,
    required this.source,
    required this.title,
    required this.status,
    required this.iconName,
    required this.iconThemePath,
    required this.iconPixmap,
    required this.menuAvailable,
    required this.primaryOpensMenu,
    this.menuPath = '',
  });

  final String id;
  final SystemTrayItemSource source;
  final String title;
  final SystemTrayStatus status;
  final String iconName;
  final String iconThemePath;
  final SystemTrayIconPixmap? iconPixmap;
  final bool menuAvailable;
  final bool primaryOpensMenu;
  final String menuPath;

  @override
  bool operator ==(Object other) {
    return other is SystemTrayItem &&
        other.id == id &&
        other.source == source &&
        other.title == title &&
        other.status == status &&
        other.iconName == iconName &&
        other.iconThemePath == iconThemePath &&
        other.iconPixmap == iconPixmap &&
        other.menuAvailable == menuAvailable &&
        other.primaryOpensMenu == primaryOpensMenu &&
        other.menuPath == menuPath;
  }

  @override
  int get hashCode => Object.hash(
    id,
    source,
    title,
    status,
    iconName,
    iconThemePath,
    iconPixmap,
    menuAvailable,
    primaryOpensMenu,
    menuPath,
  );
}

enum XEmbedTrayEventKind { added, updated, removed }

@immutable
class XEmbedTrayEvent {
  const XEmbedTrayEvent({
    required this.kind,
    required this.windowId,
    this.item,
  });

  final XEmbedTrayEventKind kind;
  final int windowId;
  final SystemTrayItem? item;
}
