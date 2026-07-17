import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum HyprSurfaceRole { root, subsurface, popup }

@immutable
class HyprSurfaceLayer {
  const HyprSurfaceLayer({
    required this.surfaceId,
    required this.parentSurfaceId,
    required this.popupRootSurfaceId,
    required this.role,
    required this.textureId,
    required this.width,
    required this.height,
    required this.surfaceX,
    required this.surfaceY,
    required this.surfaceWidth,
    required this.surfaceHeight,
    required this.textureSourceX,
    required this.textureSourceY,
    required this.textureSourceWidth,
    required this.textureSourceHeight,
    required this.transform,
    required this.scale120,
    required this.compositionOrder,
    this.opacity = 1.0,
  });

  final int surfaceId;
  final int parentSurfaceId;
  final int popupRootSurfaceId;
  final HyprSurfaceRole role;
  final int textureId;
  final int width;
  final int height;
  final double surfaceX;
  final double surfaceY;
  final double surfaceWidth;
  final double surfaceHeight;
  final double textureSourceX;
  final double textureSourceY;
  final double textureSourceWidth;
  final double textureSourceHeight;
  final int transform;
  final int scale120;
  final int compositionOrder;
  final double opacity;

  bool get belongsToPopup => popupRootSurfaceId > 0;

  Rect get logicalRect => Rect.fromLTWH(
        surfaceX,
        surfaceY,
        surfaceWidth,
        surfaceHeight,
      );

  @override
  bool operator ==(Object other) {
    return other is HyprSurfaceLayer &&
        other.surfaceId == surfaceId &&
        other.parentSurfaceId == parentSurfaceId &&
        other.popupRootSurfaceId == popupRootSurfaceId &&
        other.role == role &&
        other.textureId == textureId &&
        other.width == width &&
        other.height == height &&
        other.surfaceX == surfaceX &&
        other.surfaceY == surfaceY &&
        other.surfaceWidth == surfaceWidth &&
        other.surfaceHeight == surfaceHeight &&
        other.textureSourceX == textureSourceX &&
        other.textureSourceY == textureSourceY &&
        other.textureSourceWidth == textureSourceWidth &&
        other.textureSourceHeight == textureSourceHeight &&
        other.transform == transform &&
        other.scale120 == scale120 &&
        other.compositionOrder == compositionOrder &&
        other.opacity == opacity;
  }

  @override
  int get hashCode => Object.hashAll(<Object>[
        surfaceId,
        parentSurfaceId,
        popupRootSurfaceId,
        role,
        textureId,
        width,
        height,
        surfaceX,
        surfaceY,
        surfaceWidth,
        surfaceHeight,
        textureSourceX,
        textureSourceY,
        textureSourceWidth,
        textureSourceHeight,
        transform,
        scale120,
        compositionOrder,
        opacity,
      ]);
}

class HyprWindow {
  const HyprWindow({
    required this.objectId,
    required this.objectKind,
    required this.surfaceId,
    required this.windowId,
    required this.textureId,
    required this.title,
    required this.appId,
    required this.width,
    required this.height,
    required this.surfaceX,
    required this.surfaceY,
    required this.surfaceWidth,
    required this.surfaceHeight,
    required this.textureSourceX,
    required this.textureSourceY,
    required this.textureSourceWidth,
    required this.textureSourceHeight,
    required this.geometryX,
    required this.geometryY,
    required this.geometryWidth,
    required this.geometryHeight,
    required this.monitorId,
    required this.transform,
    required this.scale120,
    this.pinned = false,
    this.suppressAnimations = false,
    this.serverSideDecorated = true,
    this.opacity = 1.0,
    this.statusColorArgb,
    this.contentX = 0.0,
    this.contentY = 0.0,
    this.contentWidth = 0.0,
    this.contentHeight = 0.0,
    this.surfaceLayers = const <HyprSurfaceLayer>[],
  });

  final int objectId;
  final String objectKind;
  final int surfaceId;
  final int windowId;
  final int textureId;
  final String title;
  final String appId;
  final int width;
  final int height;
  final double surfaceX;
  final double surfaceY;
  final double surfaceWidth;
  final double surfaceHeight;
  final double textureSourceX;
  final double textureSourceY;
  final double textureSourceWidth;
  final double textureSourceHeight;
  final double geometryX;
  final double geometryY;
  final double geometryWidth;
  final double geometryHeight;
  final int monitorId;
  final int transform;
  final int scale120;
  final bool pinned;
  final bool suppressAnimations;
  final bool serverSideDecorated;
  final double opacity;
  final int? statusColorArgb;
  final double contentX;
  final double contentY;
  final double contentWidth;
  final double contentHeight;
  final List<HyprSurfaceLayer> surfaceLayers;

  bool get isHome => appId == 'denia-home' || title == 'denia-home';

  bool get isSystemUi =>
      appId.startsWith('denia-systemui') || title.startsWith('denia-systemui');

  bool get isUserApp => !isHome && !isSystemUi;

  Rect? get geometry => geometryWidth > 0.0 && geometryHeight > 0.0
      ? Rect.fromLTWH(geometryX, geometryY, geometryWidth, geometryHeight)
      : null;

  Rect get contentCoordinateRect {
    if (contentWidth > 0.0 && contentHeight > 0.0) {
      return Rect.fromLTWH(contentX, contentY, contentWidth, contentHeight);
    }
    final fallbackWidth = surfaceWidth > 0.0 ? surfaceWidth : width.toDouble();
    final fallbackHeight =
        surfaceHeight > 0.0 ? surfaceHeight : height.toDouble();
    return Rect.fromLTWH(surfaceX, surfaceY, fallbackWidth, fallbackHeight);
  }

  Iterable<HyprSurfaceLayer> get mainSurfaceLayers =>
      surfaceLayers.where((layer) => !layer.belongsToPopup);

  Iterable<HyprSurfaceLayer> get popupSurfaceLayers =>
      surfaceLayers.where((layer) => layer.belongsToPopup);

  Iterable<HyprSurfaceLayer> get popupRoots => surfaceLayers.where(
        (layer) => layer.role == HyprSurfaceRole.popup,
      );

  Iterable<int> get visibleSurfaceIds sync* {
    if (surfaceLayers.isEmpty) {
      if (textureId > 0) {
        yield surfaceId;
      }
      return;
    }
    for (final layer in surfaceLayers) {
      if (layer.textureId > 0) {
        yield layer.surfaceId;
      }
    }
  }

  Rect mapSurfaceRect(HyprSurfaceLayer layer, Rect targetContentRect) {
    final source = contentCoordinateRect;
    if (source.width <= 0.0 ||
        source.height <= 0.0 ||
        targetContentRect.width <= 0.0 ||
        targetContentRect.height <= 0.0) {
      return Rect.zero;
    }
    final scaleX = targetContentRect.width / source.width;
    final scaleY = targetContentRect.height / source.height;
    return Rect.fromLTWH(
      targetContentRect.left + (layer.surfaceX - source.left) * scaleX,
      targetContentRect.top + (layer.surfaceY - source.top) * scaleY,
      layer.surfaceWidth * scaleX,
      layer.surfaceHeight * scaleY,
    );
  }

  String get displayTitle {
    if (title.trim().isNotEmpty) {
      return title.trim();
    }
    if (appId.trim().isNotEmpty) {
      return appId.trim();
    }
    return 'Window $windowId';
  }

  @override
  bool operator ==(Object other) {
    return other is HyprWindow &&
        other.objectId == objectId &&
        other.objectKind == objectKind &&
        other.surfaceId == surfaceId &&
        other.windowId == windowId &&
        other.textureId == textureId &&
        other.title == title &&
        other.appId == appId &&
        other.width == width &&
        other.height == height &&
        other.surfaceX == surfaceX &&
        other.surfaceY == surfaceY &&
        other.surfaceWidth == surfaceWidth &&
        other.surfaceHeight == surfaceHeight &&
        other.textureSourceX == textureSourceX &&
        other.textureSourceY == textureSourceY &&
        other.textureSourceWidth == textureSourceWidth &&
        other.textureSourceHeight == textureSourceHeight &&
        other.geometryX == geometryX &&
        other.geometryY == geometryY &&
        other.geometryWidth == geometryWidth &&
        other.geometryHeight == geometryHeight &&
        other.monitorId == monitorId &&
        other.transform == transform &&
        other.scale120 == scale120 &&
        other.pinned == pinned &&
        other.suppressAnimations == suppressAnimations &&
        other.serverSideDecorated == serverSideDecorated &&
        other.opacity == opacity &&
        other.statusColorArgb == statusColorArgb &&
        other.contentX == contentX &&
        other.contentY == contentY &&
        other.contentWidth == contentWidth &&
        other.contentHeight == contentHeight &&
        listEquals(other.surfaceLayers, surfaceLayers);
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
        objectId,
        objectKind,
        surfaceId,
        windowId,
        textureId,
        title,
        appId,
        width,
        height,
        surfaceX,
        surfaceY,
        surfaceWidth,
        surfaceHeight,
        textureSourceX,
        textureSourceY,
        textureSourceWidth,
        textureSourceHeight,
        geometryX,
        geometryY,
        geometryWidth,
        geometryHeight,
        monitorId,
        transform,
        scale120,
        pinned,
        suppressAnimations,
        serverSideDecorated,
        opacity,
        statusColorArgb,
        contentX,
        contentY,
        contentWidth,
        contentHeight,
        ...surfaceLayers,
      ]);
}
