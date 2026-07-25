import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';

class ShellMetrics {
  const ShellMetrics._();

  static const double gestureHitWidth = 176.0;
  static const double gestureHitHeight = 72.0;
  static const double gestureBottomInset = -8.0;
  static const double edgePanelGestureWidth = 220.0;
  static const double edgePanelGestureHeight = 18.0;
  static const double edgePanelMaxHeight = 368.0;
  static const double edgePanelOpenDistance = 86.0;
  static const double edgePanelDragDistance = edgePanelMaxHeight;
  static const double edgePanelScrollStripWidth = 18.0;
  static const double edgePanelScrollMultiplier = 1.15;

  /// Visual gutter between the outgoing and incoming windows during a
  /// horizontal app switch. The switch animation must travel `width + this`
  /// so the incoming window lands exactly centred.
  static const double appSwitchGap = 18.0;
  static const double statusBarHeight = 48.0;
  static const double appStatusBarHeight = statusBarHeight;
  static const double statusDragHeight = statusBarHeight;
  static const double quickSettingsPanelHeight = 488.0;
  static const double quickSettingsDragDistance = quickSettingsPanelHeight;

  static double appStatusBarTextureHeight(
    DenialWindow window, {
    Size? targetSize,
    double visualHeight = appStatusBarHeight,
  }) {
    if (!window.isUserApp || window.width <= 0) {
      return 0.0;
    }

    if (targetSize != null &&
        targetSize.width > 0.0 &&
        targetSize.height > visualHeight &&
        visualHeight > 0.0 &&
        window.height > 0) {
      final textureWidth = window.width.toDouble();
      final textureHeight = window.height.toDouble();
      final widthScale = targetSize.width / textureWidth;

      if (widthScale.isFinite && widthScale > 0.0) {
        if (widthScale * textureHeight + visualHeight >= targetSize.height) {
          return visualHeight / widthScale;
        }
        return visualHeight *
            textureHeight /
            (targetSize.height - visualHeight);
      }
    }

    final scale = window.scale120 > 0 ? window.scale120 / 120.0 : 1.0;
    return visualHeight * scale;
  }

  static double windowFrameTextureHeight(DenialWindow window) {
    return window.height.toDouble() + appStatusBarTextureHeight(window);
  }

  static Rect gestureRect(Size viewSize) {
    final width = gestureHitWidth.clamp(0.0, viewSize.width);
    final left = (viewSize.width - width) / 2.0;
    final top = viewSize.height - gestureHitHeight - gestureBottomInset;
    return Rect.fromLTWH(left, top, width, gestureHitHeight);
  }

  static Rect edgePanelGestureRect(Size viewSize) {
    final width = edgePanelGestureWidth.clamp(0.0, viewSize.width);
    final top = viewSize.height - edgePanelGestureHeight - gestureBottomInset;
    return Rect.fromLTWH(
      viewSize.width - width,
      top,
      width,
      edgePanelGestureHeight,
    );
  }

  static double edgePanelHeight(Size viewSize) {
    if (viewSize.height <= 0.0) {
      return 0.0;
    }
    final maxHeight = viewSize.height < edgePanelMaxHeight
        ? viewSize.height
        : edgePanelMaxHeight;
    return (viewSize.height * 0.30).clamp(0.0, maxHeight).toDouble();
  }

  static Rect edgePanelRect(Size viewSize, double progress) {
    final height = edgePanelHeight(viewSize) * progress.clamp(0.0, 1.0);
    return Rect.fromLTWH(
      0,
      viewSize.height - height,
      viewSize.width,
      height,
    );
  }

  static Rect edgePanelScrollStripRect(Size viewSize) {
    final width = edgePanelScrollStripWidth.clamp(0.0, viewSize.width);
    final panelHeight = edgePanelHeight(viewSize);
    return Rect.fromLTWH(
      viewSize.width - width,
      0,
      width,
      (viewSize.height - panelHeight).clamp(0.0, viewSize.height).toDouble(),
    );
  }

  static Rect statusRect(Size viewSize) {
    return Rect.fromLTWH(
      0,
      0,
      viewSize.width,
      statusDragHeight.clamp(0.0, viewSize.height),
    );
  }
}

class InputLayoutSnapshot {
  const InputLayoutSnapshot({
    required this.epoch,
    required this.shellRegions,
    required this.windows,
    this.visibleSurfaceIds = const <int>[],
    this.keyboardCapture = false,
    this.exclusiveShellMode = false,
  });

  final int epoch;
  final List<Rect> shellRegions;
  final List<InputWindowRegion> windows;
  final List<int> visibleSurfaceIds;
  final bool keyboardCapture;
  final bool exclusiveShellMode;

  bool hasSameRoutingAs(InputLayoutSnapshot other) {
    if (keyboardCapture != other.keyboardCapture ||
        exclusiveShellMode != other.exclusiveShellMode ||
        shellRegions.length != other.shellRegions.length ||
        windows.length != other.windows.length ||
        visibleSurfaceIds.length != other.visibleSurfaceIds.length) {
      return false;
    }
    for (var index = 0; index < shellRegions.length; index += 1) {
      if (!_sameWireRect(shellRegions[index], other.shellRegions[index])) {
        return false;
      }
    }
    for (var index = 0; index < windows.length; index += 1) {
      if (!windows[index].hasSameRoutingAs(other.windows[index])) {
        return false;
      }
    }
    for (var index = 0; index < visibleSurfaceIds.length; index += 1) {
      if (visibleSurfaceIds[index] != other.visibleSurfaceIds[index]) {
        return false;
      }
    }
    return true;
  }
}

class InputWindowRegion {
  const InputWindowRegion({
    required this.window,
    required this.rect,
    required this.sourceRect,
    required this.z,
    this.surfaceId,
    this.visible = true,
    this.hitTest = true,
    this.geometryLocked = false,
  });

  final DenialWindow window;
  final Rect rect;
  final Rect sourceRect;
  final int z;
  final int? surfaceId;
  final bool visible;
  final bool hitTest;
  final bool geometryLocked;

  int get targetSurfaceId => surfaceId ?? window.surfaceId;

  bool hasSameRoutingAs(InputWindowRegion other) {
    return window.objectId == other.window.objectId &&
        targetSurfaceId == other.targetSurfaceId &&
        window.windowId == other.window.windowId &&
        z == other.z &&
        visible == other.visible &&
        hitTest == other.hitTest &&
        geometryLocked == other.geometryLocked &&
        _sameWireRect(rect, other.rect) &&
        _sameWireRect(sourceRect, other.sourceRect);
  }
}

bool _sameWireRect(Rect left, Rect right) {
  return _sameWireCoordinate(left.left, right.left) &&
      _sameWireCoordinate(left.top, right.top) &&
      _sameWireCoordinate(left.width, right.width) &&
      _sameWireCoordinate(left.height, right.height);
}

bool _sameWireCoordinate(double left, double right) {
  if (!left.isFinite || !right.isFinite) {
    return left == right;
  }
  return (left * 1000).round() == (right * 1000).round();
}
