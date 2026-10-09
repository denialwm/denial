import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'denial_pet.dart';
import 'surface_occlusion.dart';

enum DenialWindowContentKind {
  surfaceTree,
  localFlutter,
  layerShellBackground,
  layerShellBottom,
  layerShellTop,
  layerShellOverlay,
  popupSurface,
}

enum DenialSurfaceRole { root, subsurface, popup }

enum DenialWindowOpacityClass {
  contentTranslucent,
  borderAlphaOnly,
  fullyOpaque,
}

@immutable
class DenialSurfaceLayer {
  const DenialSurfaceLayer({
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
    this.opaque = false,
    this.windowGeometry,
  });

  final int surfaceId;
  final int parentSurfaceId;
  final int popupRootSurfaceId;
  final DenialSurfaceRole role;
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
  final bool opaque;

  /// The visible part of a popup root in surface-local logical coordinates:
  /// its xdg window geometry, without a client-drawn drop shadow. Null when
  /// the complete surface is visible.
  final Rect? windowGeometry;

  bool get belongsToPopup => popupRootSurfaceId > 0;

  /// [windowGeometry] in fractions of the surface size, which stays valid
  /// wherever the surface is laid out or scaled.
  Rect? get windowGeometryFraction {
    final geometry = windowGeometry;
    if (geometry == null || surfaceWidth <= 0 || surfaceHeight <= 0) {
      return null;
    }
    return Rect.fromLTRB(
      geometry.left / surfaceWidth,
      geometry.top / surfaceHeight,
      geometry.right / surfaceWidth,
      geometry.bottom / surfaceHeight,
    );
  }

  Rect get logicalRect =>
      Rect.fromLTWH(surfaceX, surfaceY, surfaceWidth, surfaceHeight);

  @override
  bool operator ==(Object other) {
    return other is DenialSurfaceLayer &&
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
        other.opacity == opacity &&
        other.opaque == opaque &&
        other.windowGeometry == windowGeometry;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
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
    opaque,
    windowGeometry,
  ]);
}

class DenialWindow {
  const DenialWindow({
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
    this.workspaceId = 1,
    this.transientParentObjectId,
    this.minimized = false,
    this.fullscreen = false,
    this.maximized = false,
    required this.transform,
    required this.scale120,
    this.pinned = false,
    this.suppressAnimations = false,
    this.restoredAcrossFlutterRestart = false,
    this.serverSideDecorated = true,
    this.opacity = 1.0,
    this.statusColorArgb,
    this.contentX = 0.0,
    this.contentY = 0.0,
    this.contentWidth = 0.0,
    this.contentHeight = 0.0,
    this.surfaceLayers = const <DenialSurfaceLayer>[],
    this.contentKind = DenialWindowContentKind.surfaceTree,
    this.opacityClass = DenialWindowOpacityClass.contentTranslucent,
    this.pet,
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
  final int workspaceId;
  final int? transientParentObjectId;
  final bool minimized;
  final bool fullscreen;
  final bool maximized;
  final int transform;
  final int scale120;
  final bool pinned;
  final bool suppressAnimations;
  final bool restoredAcrossFlutterRestart;
  final bool serverSideDecorated;
  final double opacity;
  final int? statusColorArgb;
  final double contentX;
  final double contentY;
  final double contentWidth;
  final double contentHeight;
  final List<DenialSurfaceLayer> surfaceLayers;
  final DenialWindowContentKind contentKind;
  final DenialWindowOpacityClass opacityClass;

  /// What the shell knows of this layer surface if it is a desktop pet
  /// (denial-pet-v1); null for anything else.
  final DenialPet? pet;

  /// The window holding this layer surface, if it is a pet one holds. A held
  /// pet is drawn and hit with that window instead of in its layer's plane.
  /// While the pet is dragged, this is the hold it takes if let go now.
  DenialPetHold? get heldBy => isLayerShell ? pet?.held : null;

  /// Whether a window holds this layer surface; see [heldBy].
  bool get isHeld => heldBy != null;

  bool get isLocalFlutter =>
      contentKind == DenialWindowContentKind.localFlutter;

  bool get isLayerShell => switch (contentKind) {
    DenialWindowContentKind.layerShellBackground ||
    DenialWindowContentKind.layerShellBottom ||
    DenialWindowContentKind.layerShellTop ||
    DenialWindowContentKind.layerShellOverlay => true,
    DenialWindowContentKind.surfaceTree ||
    DenialWindowContentKind.localFlutter ||
    DenialWindowContentKind.popupSurface => false,
  };

  bool get isPopupSurface =>
      contentKind == DenialWindowContentKind.popupSurface;

  bool get isHome => appId == 'denia-home' || title == 'denia-home';

  bool get isSystemUi =>
      appId.startsWith('denia-systemui') || title.startsWith('denia-systemui');

  bool get isInputMethodPopup =>
      isPopupSurface &&
      (appId == 'denia-systemui-input-method' ||
          title == 'denia-systemui-input-method');

  bool get isUserApp =>
      !isLayerShell && !isPopupSurface && !isHome && !isSystemUi;

  /// Whether this scene entry should play Denial's one-time window entrance.
  ///
  /// A replacement Flutter engine reconstructs windows which were already
  /// visible in its predecessor. That lifecycle fact is deliberately separate
  /// from [suppressAnimations], which is lasting window policy for transient
  /// surfaces and also controls their close effects.
  bool get shouldAnimateEntrance =>
      !suppressAnimations && !restoredAcrossFlutterRestart;

  Rect? get geometry => geometryWidth > 0.0 && geometryHeight > 0.0
      ? Rect.fromLTWH(geometryX, geometryY, geometryWidth, geometryHeight)
      : null;

  Rect get contentCoordinateRect {
    if (contentWidth > 0.0 && contentHeight > 0.0) {
      return Rect.fromLTWH(contentX, contentY, contentWidth, contentHeight);
    }
    final fallbackWidth = surfaceWidth > 0.0 ? surfaceWidth : width.toDouble();
    final fallbackHeight = surfaceHeight > 0.0
        ? surfaceHeight
        : height.toDouble();
    return Rect.fromLTWH(surfaceX, surfaceY, fallbackWidth, fallbackHeight);
  }

  /// Native frame bounds include any compositor-owned system-bar strip.
  Rect get presentationCoordinateRect => surfaceWidth > 0 && surfaceHeight > 0
      ? Rect.fromLTWH(surfaceX, surfaceY, surfaceWidth, surfaceHeight)
      : contentCoordinateRect;

  double get nativeInsetTop =>
      (contentCoordinateRect.top - presentationCoordinateRect.top)
          .clamp(0.0, presentationCoordinateRect.height)
          .toDouble();

  Iterable<DenialSurfaceLayer> get mainSurfaceLayers =>
      surfaceLayers.where((layer) => !layer.belongsToPopup);

  /// Paint only layers that can contribute to the clipped window. Keep the
  /// protocol tree intact for input, popup parenting and future unocclusion.
  /// An opaque layer must cover the entire destination of a lower layer;
  /// partial coverage and translucent overlaps retain normal composition.
  List<DenialSurfaceLayer> get paintedMainSurfaceLayers {
    final clip = presentationCoordinateRect;
    return unoccludedSurfaceLayers(
      surfaceLayers,
      clip: (
        left: clip.left,
        top: clip.top,
        right: clip.right,
        bottom: clip.bottom,
      ),
      paints: (layer) =>
          !layer.belongsToPopup && layer.textureId > 0 && layer.opacity > 0,
      opaque: (layer) => layer.opaque && layer.opacity == 1,
      bounds: (layer) => (
        left: layer.surfaceX,
        top: layer.surfaceY,
        right: layer.surfaceX + layer.surfaceWidth,
        bottom: layer.surfaceY + layer.surfaceHeight,
      ),
    );
  }

  Iterable<DenialSurfaceLayer> get popupSurfaceLayers =>
      surfaceLayers.where((layer) => layer.belongsToPopup);

  Iterable<DenialSurfaceLayer> get popupRoots =>
      surfaceLayers.where((layer) => layer.role == DenialSurfaceRole.popup);

  /// Hit-test order without materializing a reversed copy of the popup list.
  Iterable<DenialSurfaceLayer> get popupRootsFrontToBack => surfaceLayers
      .reversed
      .where((layer) => layer.role == DenialSurfaceRole.popup);

  /// Whether the root surface fully hides every pixel behind this window.
  bool get isOpaque =>
      !isLocalFlutter &&
      opacity >= 1.0 &&
      opacityClass == DenialWindowOpacityClass.fullyOpaque;

  /// Whether transparency reaches meaningful application content rather than
  /// being confined to client-side shadows or antialiased window borders.
  bool get isContentTranslucent =>
      opacityClass == DenialWindowOpacityClass.contentTranslucent;

  /// Texture-backed surfaces drawn inside the toplevel frame itself.
  ///
  /// Desktop widgets use this narrower visibility set because popup surfaces
  /// are intentionally absent from their compact representation.
  Iterable<int> get mainVisibleSurfaceIds sync* {
    if (surfaceLayers.isEmpty) {
      if (textureId > 0) {
        yield surfaceId;
      }
      return;
    }
    for (final layer in paintedMainSurfaceLayers) {
      if (layer.textureId > 0) {
        yield layer.surfaceId;
      }
    }
  }

  Iterable<int> get visibleSurfaceIds sync* {
    if (surfaceLayers.isEmpty) {
      if (textureId > 0) {
        yield surfaceId;
      }
      return;
    }
    for (final layer in [...paintedMainSurfaceLayers, ...popupSurfaceLayers]) {
      if (layer.textureId > 0) {
        yield layer.surfaceId;
      }
    }
  }

  Rect mapSurfaceRect(DenialSurfaceLayer layer, Rect targetContentRect) {
    final source = presentationCoordinateRect;
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
    // Presentation layers replace this identifier with a localized fallback.
    return windowId.toString();
  }

  /// Whether this window keeps the same role in the static desktop scene.
  ///
  /// During a native move/resize grab, the keyed window and popup consumers
  /// sample live placement and texture metadata independently. Buffer size,
  /// crop, opacity, and surface-tree updates therefore do not require the
  /// surrounding wallpaper, bars, panels, or other windows to rebuild.
  bool hasSameStaticSceneRoleAs(DenialWindow other) {
    if (identical(this, other)) return true;
    return other.objectId == objectId &&
        other.objectKind == objectKind &&
        other.surfaceId == surfaceId &&
        other.windowId == windowId &&
        other.appId == appId &&
        other.monitorId == monitorId &&
        other.workspaceId == workspaceId &&
        other.transientParentObjectId == transientParentObjectId &&
        other.minimized == minimized &&
        other.fullscreen == fullscreen &&
        other.maximized == maximized &&
        other.pinned == pinned &&
        other.suppressAnimations == suppressAnimations &&
        other.restoredAcrossFlutterRestart == restoredAcrossFlutterRestart &&
        other.serverSideDecorated == serverSideDecorated &&
        other.contentKind == contentKind &&
        other.heldBy?.windowId == heldBy?.windowId &&
        other.pet?.below == pet?.below;
  }

  /// Whether every field that can change the composed desktop scene matches.
  ///
  /// A title update only changes presentation metadata such as accessibility
  /// labels and switcher text. Keyed consumers can update that one window
  /// without invalidating geometry, textures, or the other scene windows.
  bool hasSameSceneDescriptionAs(DenialWindow other) {
    if (identical(this, other)) return true;
    return other.objectId == objectId &&
        other.objectKind == objectKind &&
        other.surfaceId == surfaceId &&
        other.windowId == windowId &&
        other.textureId == textureId &&
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
        other.workspaceId == workspaceId &&
        other.transientParentObjectId == transientParentObjectId &&
        other.minimized == minimized &&
        other.fullscreen == fullscreen &&
        other.maximized == maximized &&
        other.transform == transform &&
        other.scale120 == scale120 &&
        other.pinned == pinned &&
        other.suppressAnimations == suppressAnimations &&
        other.restoredAcrossFlutterRestart == restoredAcrossFlutterRestart &&
        other.serverSideDecorated == serverSideDecorated &&
        other.opacity == opacity &&
        other.statusColorArgb == statusColorArgb &&
        other.contentX == contentX &&
        other.contentY == contentY &&
        other.contentWidth == contentWidth &&
        other.contentHeight == contentHeight &&
        other.contentKind == contentKind &&
        other.opacityClass == opacityClass &&
        other.pet == pet &&
        listEquals(other.surfaceLayers, surfaceLayers);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DenialWindow &&
            other.title == title &&
            hasSameSceneDescriptionAs(other);
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
    workspaceId,
    transientParentObjectId,
    minimized,
    fullscreen,
    maximized,
    transform,
    scale120,
    pinned,
    suppressAnimations,
    restoredAcrossFlutterRestart,
    serverSideDecorated,
    opacity,
    statusColorArgb,
    contentX,
    contentY,
    contentWidth,
    contentHeight,
    contentKind,
    pet,
    ...surfaceLayers,
  ]);
}
