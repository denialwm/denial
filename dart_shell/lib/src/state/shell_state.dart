import 'package:flutter/widgets.dart';

import '../input/input_layout.dart';
import '../models/app_launch_request.dart';
import '../models/denial_window.dart';

class ShellState {
  const ShellState({
    required this.windows,
    required this.windowSnapshotSequence,
    required this.overviewVisible,
    required this.gestureDrag,
    required this.quickSettingsVisible,
    required this.quickSettingsDrag,
    required this.quickSettingsDragActive,
    required this.edgePanelVisible,
    required this.edgePanelDrag,
    required this.edgePanelDragActive,
    required this.edgePanelViewportScroll,
    required this.locked,
    required this.lockLayerVisible,
    required this.foregroundObjectId,
    required this.launchingObjectId,
    required this.launchRequest,
    required this.homeTransitionActive,
  });

  factory ShellState.initial({bool locked = false}) {
    return ShellState(
      windows: <DenialWindow>[],
      windowSnapshotSequence: 0,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      edgePanelViewportScroll: 0.0,
      locked: locked,
      lockLayerVisible: locked,
      foregroundObjectId: null,
      launchingObjectId: null,
      launchRequest: null,
      homeTransitionActive: false,
    );
  }

  final List<DenialWindow> windows;
  final int windowSnapshotSequence;
  final bool overviewVisible;
  final Offset gestureDrag;
  final bool quickSettingsVisible;
  final Offset quickSettingsDrag;
  final bool quickSettingsDragActive;
  final bool edgePanelVisible;
  final Offset edgePanelDrag;
  final bool edgePanelDragActive;
  final double edgePanelViewportScroll;
  final bool locked;
  final bool lockLayerVisible;
  final int? foregroundObjectId;
  final int? launchingObjectId;
  final AppLaunchRequest? launchRequest;

  /// True while the foreground app is flying away to reveal home, so the
  /// fullscreen primary stage stays hidden until the transition resolves.
  final bool homeTransitionActive;

  double get overviewDragProgress {
    if (overviewVisible) {
      return 1.0;
    }

    return (-gestureDrag.dy / 280.0).clamp(0.0, 1.0).toDouble();
  }

  double get quickSettingsDragProgress {
    if (quickSettingsVisible) {
      return 1.0;
    }

    return (quickSettingsDrag.dy / ShellMetrics.quickSettingsDragDistance)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double get edgePanelDragProgress {
    if (edgePanelVisible) {
      return 1.0;
    }

    return (edgePanelDrag.dy / ShellMetrics.edgePanelDragDistance)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  ShellState copyWith({
    List<DenialWindow>? windows,
    int? windowSnapshotSequence,
    bool? overviewVisible,
    Offset? gestureDrag,
    bool? quickSettingsVisible,
    Offset? quickSettingsDrag,
    bool? quickSettingsDragActive,
    bool? edgePanelVisible,
    Offset? edgePanelDrag,
    bool? edgePanelDragActive,
    double? edgePanelViewportScroll,
    bool? locked,
    bool? lockLayerVisible,
    int? foregroundObjectId,
    bool clearForegroundObjectId = false,
    int? launchingObjectId,
    bool clearLaunchingObjectId = false,
    AppLaunchRequest? launchRequest,
    bool clearLaunchRequest = false,
    bool? homeTransitionActive,
  }) {
    return ShellState(
      windows: windows ?? this.windows,
      windowSnapshotSequence:
          windowSnapshotSequence ?? this.windowSnapshotSequence,
      overviewVisible: overviewVisible ?? this.overviewVisible,
      gestureDrag: gestureDrag ?? this.gestureDrag,
      quickSettingsVisible: quickSettingsVisible ?? this.quickSettingsVisible,
      quickSettingsDrag: quickSettingsDrag ?? this.quickSettingsDrag,
      quickSettingsDragActive:
          quickSettingsDragActive ?? this.quickSettingsDragActive,
      edgePanelVisible: edgePanelVisible ?? this.edgePanelVisible,
      edgePanelDrag: edgePanelDrag ?? this.edgePanelDrag,
      edgePanelDragActive: edgePanelDragActive ?? this.edgePanelDragActive,
      edgePanelViewportScroll:
          edgePanelViewportScroll ?? this.edgePanelViewportScroll,
      locked: locked ?? this.locked,
      lockLayerVisible: lockLayerVisible ?? this.lockLayerVisible,
      foregroundObjectId: clearForegroundObjectId
          ? null
          : foregroundObjectId ?? this.foregroundObjectId,
      launchingObjectId: clearLaunchingObjectId
          ? null
          : launchingObjectId ?? this.launchingObjectId,
      launchRequest: clearLaunchRequest
          ? null
          : launchRequest ?? this.launchRequest,
      homeTransitionActive: homeTransitionActive ?? this.homeTransitionActive,
    );
  }

  DenialWindow? get foregroundWindow {
    final window = windowByObjectId(foregroundObjectId);
    return window != null && window.isUserApp ? window : null;
  }

  DenialWindow? get launchingWindow {
    final window = windowByObjectId(launchingObjectId);
    return window != null && window.isUserApp ? window : null;
  }

  bool get launchTransitionActive => launchRequest != null;

  DenialWindow? get primaryWindow {
    if (launchTransitionActive) {
      return null;
    }

    return foregroundWindow;
  }

  DenialWindow? get inputWindow {
    if (lockLayerVisible || launchTransitionActive || overviewVisible) {
      return null;
    }

    return primaryWindow;
  }

  List<DenialWindow> get openAppWindows {
    return windows.where((window) => window.isUserApp).toList(growable: false);
  }

  int get openAppWindowCount {
    var count = 0;
    for (final window in windows) {
      if (window.isUserApp) {
        count += 1;
      }
    }
    return count;
  }

  DenialWindow? get appSwitchTargetWindow {
    if (lockLayerVisible ||
        overviewVisible ||
        quickSettingsDragProgress > 0.0 ||
        edgePanelDragProgress > 0.0) {
      return null;
    }

    final dx = gestureDrag.dx;
    if (dx == 0.0) {
      return null;
    }

    return adjacentOpenAppWindow(dx > 0.0 ? -1 : 1);
  }

  DenialWindow? adjacentOpenAppWindow(int direction) {
    if (direction == 0) {
      return null;
    }

    final currentObjectId = foregroundObjectId ?? primaryWindow?.objectId;
    var currentIndex = -1;
    var lastUserIndex = -1;
    var userWindowCount = 0;
    for (var index = 0; index < windows.length; index += 1) {
      final window = windows[index];
      if (!window.isUserApp) {
        continue;
      }
      userWindowCount += 1;
      lastUserIndex = index;
      if (window.objectId == currentObjectId) {
        currentIndex = index;
      }
    }
    if (userWindowCount < 2) {
      return null;
    }
    if (currentIndex < 0) {
      currentIndex = lastUserIndex;
    }

    for (
      var targetIndex = currentIndex + direction;
      targetIndex >= 0 && targetIndex < windows.length;
      targetIndex += direction
    ) {
      final target = windows[targetIndex];
      if (target.isUserApp) {
        return target;
      }
    }
    return null;
  }

  DenialWindow? windowByObjectId(int? objectId) {
    if (objectId == null) {
      return null;
    }

    for (final window in windows) {
      if (window.objectId == objectId) {
        return window;
      }
    }

    return null;
  }

  DenialWindow? windowByWindowId(int windowId) {
    for (final window in windows) {
      if (window.windowId == windowId) {
        return window;
      }
    }
    return null;
  }
}
