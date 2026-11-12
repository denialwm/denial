import 'package:flutter/widgets.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart' show ShellState;

import 'reference_shell_metrics.dart';

/// Which way the bottom gesture drags the shell's visuals, if at all.
///
/// The drag itself changes on every frame of a swipe. It lives in
/// `ReferenceShellController.gestureDrag`, which only the moving layers
/// observe; the shell state changes only when this phase does.
enum GestureDragPhase {
  idle,
  up,
  down,
  left,
  right;

  /// The phase of an axis-locked visual drag.
  static GestureDragPhase of(Offset drag) {
    if (drag.dx < 0.0) return left;
    if (drag.dx > 0.0) return right;
    if (drag.dy < 0.0) return up;
    if (drag.dy > 0.0) return down;
    return idle;
  }

  bool get horizontal => this == left || this == right;
}

/// The target of the mobile system Back action. See
/// [ReferenceShellState.backTarget].
enum MobileBackTarget { none, keyboard, shade, overview, app }

/// Reference UI state over the shared SDK snapshot. Gesture updates reuse its
/// native indexes; presentation focus may differ while home or recents is shown.
class ReferenceShellState {
  const ReferenceShellState._({
    required this.platform,
    required this.desk,
    required this.overviewVisible,
    required this.gesture,
    required this.quickSettingsVisible,
    required this.quickSettingsDragged,
    required this.quickSettingsDragActive,
    required this.edgePanelVisible,
    required this.edgePanelDrag,
    required this.edgePanelDragActive,
    required this.edgePanelViewportScroll,
    required this.lockLayerVisible,
    required this.foregroundObjectId,
    required this.launchingObjectId,
    required this.launchRequest,
    required this.homeTransitionActive,
    required this.appSwitchOrder,
  });

  factory ReferenceShellState.initial(ShellState platform) {
    return ReferenceShellState._(
      platform: platform,
      desk: platform,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      edgePanelViewportScroll: 0.0,
      lockLayerVisible: platform.locked,
      foregroundObjectId: platform.foregroundObjectId,
      launchingObjectId: null,
      launchRequest: null,
      homeTransitionActive: false,
      appSwitchOrder: const <int>[],
    );
  }

  /// The windows the mobile shell shows: all of them, or those on the phone
  /// while a desk shares the session.
  final ShellState platform;

  /// The windows the desktop shell shows: all of them, or those on the desks
  /// while they share the session with the phone. Its foreground is the
  /// native one.
  final ShellState desk;

  /// The window the desktop shell treats as focused.
  int? get deskForegroundObjectId =>
      identical(desk, platform) ? foregroundObjectId : desk.foregroundObjectId;

  /// Every open app, on the phone and on the desks.
  List<DenialWindow> get allOpenAppWindows => identical(desk, platform)
      ? openAppWindows
      : <DenialWindow>[...platform.openAppWindows, ...desk.openAppWindows];

  List<DenialWindow> get windows => platform.windows;
  List<DenialWindow> get openAppWindows => platform.openAppWindows;
  Map<int, DenialWindow> get openAppWindowsByObjectId =>
      platform.openAppWindowsByObjectId;
  List<DenialWindow> get positionedPopupSurfaces =>
      platform.positionedPopupSurfaces;
  List<DenialWindow> get layerSurfaces => platform.layerSurfaces;

  /// Denial's own overlay on top, such as the authentication prompt, which a
  /// phone shows above everything but the keyboard.
  DenialWindow? get systemOverlay {
    for (final surface in layerSurfaces.reversed) {
      if (surface.contentKind == DenialWindowContentKind.layerShellOverlay &&
          surface.appId.startsWith('dev.denial.') &&
          surface.geometry != null &&
          surface.surfaceLayers.isNotEmpty) {
        return surface;
      }
    }
    return null;
  }

  int get windowSnapshotSequence => platform.windowSnapshotSequence;
  bool get locked => platform.locked;

  final bool overviewVisible;
  final GestureDragPhase gesture;
  final bool quickSettingsVisible;

  /// A shade drag holds the shade past closed. The finger's position, which
  /// changes on every frame, is `ReferenceShellController.quickSettingsDrag`.
  final bool quickSettingsDragged;
  final bool quickSettingsDragActive;
  final bool edgePanelVisible;
  final Offset edgePanelDrag;
  final bool edgePanelDragActive;
  final double edgePanelViewportScroll;
  final bool lockLayerVisible;
  final int? foregroundObjectId;
  final int? launchingObjectId;
  final AppLaunchRequest? launchRequest;

  /// True while the foreground app is flying away to reveal home, so the
  /// fullscreen primary stage stays hidden until the transition resolves.
  final bool homeTransitionActive;

  /// App object IDs in stacking order, oldest first, frozen while a sequence
  /// of quick switches lasts. Each switch raises its target to the top, so
  /// the live order would only alternate between the two most recent apps.
  final List<int> appSwitchOrder;

  /// The shade is open or held partly open.
  bool get quickSettingsEngaged => quickSettingsVisible || quickSettingsDragged;

  double get edgePanelDragProgress {
    if (edgePanelVisible) {
      return 1.0;
    }

    return (edgePanelDrag.dy / ReferenceShellMetrics.edgePanelDragDistance)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  ReferenceShellState copyWith({
    ShellState? platform,
    ShellState? desk,
    bool? overviewVisible,
    GestureDragPhase? gesture,
    bool? quickSettingsVisible,
    bool? quickSettingsDragged,
    bool? quickSettingsDragActive,
    bool? edgePanelVisible,
    Offset? edgePanelDrag,
    bool? edgePanelDragActive,
    double? edgePanelViewportScroll,
    bool? lockLayerVisible,
    int? foregroundObjectId,
    bool clearForegroundObjectId = false,
    int? launchingObjectId,
    bool clearLaunchingObjectId = false,
    AppLaunchRequest? launchRequest,
    bool clearLaunchRequest = false,
    bool? homeTransitionActive,
    List<int>? appSwitchOrder,
  }) {
    return ReferenceShellState._(
      platform: platform ?? this.platform,
      desk: desk ?? this.desk,
      overviewVisible: overviewVisible ?? this.overviewVisible,
      gesture: gesture ?? this.gesture,
      quickSettingsVisible: quickSettingsVisible ?? this.quickSettingsVisible,
      quickSettingsDragged: quickSettingsDragged ?? this.quickSettingsDragged,
      quickSettingsDragActive:
          quickSettingsDragActive ?? this.quickSettingsDragActive,
      edgePanelVisible: edgePanelVisible ?? this.edgePanelVisible,
      edgePanelDrag: edgePanelDrag ?? this.edgePanelDrag,
      edgePanelDragActive: edgePanelDragActive ?? this.edgePanelDragActive,
      edgePanelViewportScroll:
          edgePanelViewportScroll ?? this.edgePanelViewportScroll,
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
      appSwitchOrder: appSwitchOrder ?? this.appSwitchOrder,
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

  /// The foreground app lays itself out around the on-screen keyboard
  /// (denial-insets-v1 keyboard inset), so the shell does not lift it.
  bool get primaryWindowHandlesKeyboard =>
      primaryWindow?.keyboardInset ?? false;

  DenialWindow? get inputWindow {
    if (lockLayerVisible || launchTransitionActive || overviewVisible) {
      return null;
    }

    return primaryWindow;
  }

  /// The app on screen asked for full screen: the status bar steps aside,
  /// and its strip only pulls the shade down from the top edge.
  bool get statusBarHidden => inputWindow?.fullscreen ?? false;

  /// What the system Back action acts on, in Android's order: the keyboard
  /// first, then the shade, then recents, then the foreground app.
  MobileBackTarget get backTarget {
    if (locked || lockLayerVisible || launchTransitionActive) {
      return MobileBackTarget.none;
    }
    if (edgePanelVisible) {
      return MobileBackTarget.keyboard;
    }
    if (quickSettingsEngaged) {
      return MobileBackTarget.shade;
    }
    if (overviewVisible) {
      return MobileBackTarget.overview;
    }
    return primaryWindow == null ? MobileBackTarget.none : MobileBackTarget.app;
  }

  int get openAppWindowCount => openAppWindows.length;

  /// A sideways swipe of the bottom gesture has an app to bring in.
  bool get canSwitchApps {
    // An opening app's flight holds the gesture.
    if (lockLayerVisible ||
        launchTransitionActive ||
        overviewVisible ||
        quickSettingsEngaged ||
        edgePanelDragProgress > 0.0) {
      return false;
    }
    return openAppWindowCount > (foregroundWindow == null ? 0 : 1);
  }

  DenialWindow? adjacentOpenAppWindow(int direction) {
    final foreground = foregroundObjectId;
    final index = foreground == null ? -1 : appSwitchOrder.indexOf(foreground);
    if (index < 0) {
      return platform.adjacentAppWindow(foreground, direction);
    }
    final step = direction.sign;
    if (step == 0) {
      return null;
    }
    for (var i = index + step; i >= 0 && i < appSwitchOrder.length; i += step) {
      final window = openAppWindowsByObjectId[appSwitchOrder[i]];
      if (window != null) {
        return window;
      }
    }
    return null;
  }

  DenialWindow? windowByObjectId(int? objectId) =>
      platform.windowByObjectId(objectId);
  DenialWindow? windowByWindowId(int windowId) =>
      platform.windowByWindowId(windowId);
}
