import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../config/startup_environment.dart';
import '../input/input_layout.dart';
import '../input/shell_interaction_registry.dart';
import '../models/app_launch_request.dart';
import '../models/denial_window.dart';
import '../models/denial_window_snapshot.dart';
import '../platform/denial_bridge.dart';
import '../services/lock_state_repository.dart';
import 'authentication.dart';
import 'shell_state.dart';

final denialBridgeProvider = Provider<DenialBridge>((ref) {
  final bridge = DenialBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

final shellControllerProvider =
    StateNotifierProvider<ShellController, ShellState>((ref) {
      final controller = ShellController(
        ref.read(denialBridgeProvider),
        LockStateRepository(
          environment: ref.watch(startupEnvironmentProvider).values,
        ),
        ref.read(authenticationProvider.notifier),
      );
      controller.handleAuthenticationState(ref.read(authenticationProvider));
      ref.listen<AuthenticationState>(authenticationProvider, (_, next) {
        controller.handleAuthenticationState(next);
      });
      return controller;
    });

class ShellController extends StateNotifier<ShellState> {
  ShellController(this._bridge, this._lockRepository, this._authentication)
    : super(ShellState.initial()) {
    _lockRepository.start(onChanged: _handleLockRequestChanged);
    _bridge.start(
      onWindowsChanged: _refreshWindows,
      onWindowSnapshot: _applyWindowSnapshot,
      onWindowActivated: _handleNativeWindowActivated,
    );
    unawaited(_refreshWindows());
  }

  // Large enough that the vertical swipe tracks the finger across the whole
  // screen (the home/recents hero needs the real travel, not a capped value).
  static const double _gestureVisualDistance = 1600.0;
  static const double _gestureHorizontalVisualDistance = 4096.0;
  static const double _gestureAxisLockDistance = 14.0;
  static const double _gestureAxisLockRatio = 1.18;
  static const double _quickSettingsOpenDistance = 126.0;
  static const double _quickSettingsFlickVelocity = 520.0;
  static const double _edgePanelFlickVelocity = 520.0;
  static const Duration _launchRequestTimeout = Duration(seconds: 15);

  final DenialBridge _bridge;
  final LockStateRepository _lockRepository;
  final AuthenticationController _authentication;
  int _inputLayoutEpoch = 0;
  InputLayoutSnapshot? _lastInputLayoutSnapshot;
  Offset _rawGestureDrag = Offset.zero;
  Offset _gestureLockOrigin = Offset.zero;
  _GestureAxis _gestureAxis = _GestureAxis.undecided;
  bool _quickSettingsDragStartedOpen = false;
  bool _quickSettingsDragMoved = false;
  bool _edgePanelDragStartedOpen = false;
  bool _edgePanelDragMoved = false;
  bool _refreshInProgress = false;
  bool _refreshQueued = false;
  bool _hasLoadedWindowSnapshot = false;
  int _nextLaunchRequestId = 1;
  Timer? _launchRequestTimer;
  bool? _lastMirroredNativeLock;

  @override
  void dispose() {
    _launchRequestTimer?.cancel();
    _lockRepository.dispose();
    super.dispose();
  }

  void lock() {
    _authentication.lock();
  }

  void requestUnlock() {
    _authentication.begin();
  }

  void completeUnlockTransition() {
    if (state.locked || !state.lockLayerVisible) {
      return;
    }

    _lastInputLayoutSnapshot = null;
    state = state.copyWith(lockLayerVisible: false);
  }

  void _handleLockRequestChanged(bool locked) {
    if (locked) {
      _authentication.lock();
    }
  }

  void handleAuthenticationState(AuthenticationState authentication) {
    if (!authentication.synchronized) {
      return;
    }
    if (_lastMirroredNativeLock != authentication.locked) {
      _lastMirroredNativeLock = authentication.locked;
      _lockRepository.publishSecure(authentication.locked);
      if (!authentication.locked) {
        _lockRepository.acknowledgeUnlocked();
      }
    }
    _setLockedFromNative(authentication.locked);
  }

  void _setLockedFromNative(bool locked) {
    if (state.locked == locked) {
      return;
    }

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;

    state = state.copyWith(
      locked: locked,
      lockLayerVisible: true,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      edgePanelViewportScroll: 0.0,
      homeTransitionActive: false,
      clearLaunchingObjectId: true,
      clearLaunchRequest: true,
    );
  }

  Future<void> _refreshWindows() async {
    if (_refreshInProgress) {
      _refreshQueued = true;
      return;
    }

    _refreshInProgress = true;
    try {
      do {
        _refreshQueued = false;
        try {
          final snapshot = await _bridge.listWindows(state.windows);
          if (!mounted) {
            return;
          }
          _applyWindowSnapshot(snapshot);
        } catch (_) {
          // Keep the last known snapshot. Window changes are invalidation events.
        }
      } while (_refreshQueued && mounted);
    } finally {
      _refreshInProgress = false;
      if (_refreshQueued && mounted) {
        unawaited(_refreshWindows());
      }
    }
  }

  void _applyWindowSnapshot(DenialWindowSnapshot snapshot) {
    if (_hasLoadedWindowSnapshot &&
        snapshot.sequence < state.windowSnapshotSequence) {
      return;
    }

    final windows = snapshot.windows;
    if (_hasLoadedWindowSnapshot &&
        _sameWindowSnapshots(state.windows, windows)) {
      if (snapshot.sequence > state.windowSnapshotSequence) {
        state = state.copyWith(windowSnapshotSequence: snapshot.sequence);
      }
      return;
    }

    _hasLoadedWindowSnapshot = true;
    final stableWindows = List<DenialWindow>.unmodifiable(windows);
    final request = state.launchRequest;
    final launchWindow = request == null
        ? null
        : _matchingLaunchWindow(stableWindows, request);

    if (launchWindow != null) {
      final shouldActivate = state.launchingObjectId != launchWindow.objectId;
      _rawGestureDrag = Offset.zero;
      _gestureLockOrigin = Offset.zero;
      _gestureAxis = _GestureAxis.undecided;
      state = state.copyWith(
        windows: stableWindows,
        windowSnapshotSequence: snapshot.sequence,
        overviewVisible: false,
        gestureDrag: Offset.zero,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
        foregroundObjectId: launchWindow.objectId,
        launchingObjectId: launchWindow.objectId,
      );
      if (shouldActivate) {
        _bridge.focusWindow(launchWindow);
      }
      return;
    }

    final foregroundStillVisible = _hasWindow(
      stableWindows,
      state.foregroundObjectId,
    );
    final launchingStillVisible = _hasWindow(
      stableWindows,
      state.launchingObjectId,
    );

    state = state.copyWith(
      windows: stableWindows,
      windowSnapshotSequence: snapshot.sequence,
      clearForegroundObjectId: !foregroundStillVisible,
      clearLaunchingObjectId: !launchingStillVisible,
    );
  }

  DenialWindow? _matchingLaunchWindow(
    List<DenialWindow> windows,
    AppLaunchRequest request,
  ) {
    final boundObjectId = state.launchingObjectId;
    if (boundObjectId != null) {
      for (final window in windows) {
        if (window.objectId == boundObjectId &&
            request.matchesNewWindow(window)) {
          return window;
        }
      }
    }

    for (final window in windows) {
      if (request.matchesNewWindow(window)) {
        return window;
      }
    }
    return null;
  }

  bool _hasWindow(List<DenialWindow> windows, int? objectId) {
    if (objectId == null) {
      return false;
    }

    for (final window in windows) {
      if (window.objectId == objectId) {
        return true;
      }
    }

    return false;
  }

  int? beginAppLaunch({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
  }) {
    if (state.lockLayerVisible || state.launchRequest != null) {
      return null;
    }

    final requestId = _nextLaunchRequestId++;
    final request = AppLaunchRequest(
      requestId: requestId,
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: expectedAppIds,
      existingObjectIds: state.openAppWindows.map((window) => window.objectId),
    );

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _launchRequestTimer?.cancel();
    _launchRequestTimer = Timer(_launchRequestTimeout, () {
      if (mounted) {
        failAppLaunch(requestId);
      }
    });

    state = state.copyWith(
      launchRequest: request,
      clearLaunchingObjectId: true,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      homeTransitionActive: false,
    );
    return requestId;
  }

  void failAppLaunch(int requestId) {
    if (state.launchRequest?.requestId != requestId) {
      return;
    }
    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    state = state.copyWith(
      clearLaunchRequest: true,
      clearLaunchingObjectId: true,
    );
  }

  void openOverview() {
    if (!state.overviewVisible) {
      _rawGestureDrag = Offset.zero;
      _gestureLockOrigin = Offset.zero;
      _gestureAxis = _GestureAxis.undecided;
      state = state.copyWith(
        overviewVisible: true,
        gestureDrag: Offset.zero,
        quickSettingsVisible: false,
        quickSettingsDrag: Offset.zero,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
    }
  }

  /// Begins the "fly away to home" transition. The fullscreen primary stage is
  /// hidden via [ShellState.homeTransitionActive] while the overview layer
  /// animates the current thumbnail off-screen, then calls
  /// [completeHomeTransition].
  void goHome() {
    if (state.homeTransitionActive) {
      return;
    }
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    // Clear the foreground now so home shows immediately beneath the flying
    // thumbnail; the overview layer keeps the app texture for the fly-away.
    state = state.copyWith(
      homeTransitionActive: true,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      clearForegroundObjectId: true,
    );
  }

  void completeHomeTransition() {
    if (!state.homeTransitionActive) {
      return;
    }
    state = state.copyWith(homeTransitionActive: false);
  }

  void closeOverview() {
    if (state.overviewVisible) {
      _rawGestureDrag = Offset.zero;
      _gestureLockOrigin = Offset.zero;
      _gestureAxis = _GestureAxis.undecided;
      state = state.copyWith(
        overviewVisible: false,
        gestureDrag: Offset.zero,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
        clearForegroundObjectId: true,
      );
    }
  }

  void closeWindow(DenialWindow window) {
    if (state.overviewVisible && state.openAppWindowCount <= 1) {
      closeOverview();
    }
    _bridge.closeWindow(window);
  }

  void focusWindow(DenialWindow window) {
    if (!window.isUserApp) {
      return;
    }

    _activateWindowInShell(window);
    _bridge.focusWindow(window);
  }

  /// Mirrors the compositor dropping keyboard focus after this window is
  /// minimized. A later native activation remains authoritative.
  void releaseWindowFocus(DenialWindow window) {
    if (state.foregroundObjectId != window.objectId) {
      return;
    }
    state = state.copyWith(clearForegroundObjectId: true);
  }

  void _activateWindowInShell(DenialWindow window) {
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      foregroundObjectId: window.objectId,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void _handleNativeWindowActivated(int windowId) {
    for (final window in state.windows) {
      if (window.windowId == windowId && window.isUserApp) {
        _activateWindowInShell(window);
        return;
      }
    }
  }

  void switchAdjacentWindow(int direction) {
    completeAdjacentWindowSwitch(direction);
  }

  void completeAdjacentWindowSwitch(int direction) {
    final target = state.adjacentOpenAppWindow(direction);
    if (target == null) {
      resetGestureDrag();
      return;
    }

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      foregroundObjectId: target.objectId,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      clearLaunchingObjectId: true,
    );
    _bridge.focusWindow(target);
  }

  void completeLaunchTransition(int requestId, int objectId) {
    if (state.launchRequest?.requestId != requestId ||
        state.launchingObjectId != objectId) {
      return;
    }

    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    state = state.copyWith(
      clearLaunchRequest: true,
      clearLaunchingObjectId: true,
    );
  }

  void updateGestureDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _rawGestureDrag += delta;
    _lockGestureAxis();
    final visualDrag = _visualGestureDrag(_rawGestureDrag);
    if (visualDrag == state.gestureDrag) {
      return;
    }

    state = state.copyWith(gestureDrag: visualDrag);
  }

  void resetGestureDrag() {
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    if (state.gestureDrag != Offset.zero) {
      state = state.copyWith(gestureDrag: Offset.zero);
    }
  }

  void setGestureDragForAnimation(Offset drag) {
    _rawGestureDrag = drag;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.horizontal;
    final visualDrag = _visualGestureDrag(_rawGestureDrag);
    if (visualDrag == state.gestureDrag) {
      return;
    }

    state = state.copyWith(gestureDrag: visualDrag);
  }

  void openQuickSettings() {
    if (state.quickSettingsVisible &&
        state.quickSettingsDrag == Offset.zero &&
        !state.quickSettingsDragActive) {
      return;
    }

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      quickSettingsVisible: true,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void closeQuickSettings() {
    if (!state.quickSettingsVisible &&
        state.quickSettingsDrag == Offset.zero &&
        !state.quickSettingsDragActive) {
      return;
    }

    state = state.copyWith(
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
    );
  }

  void startQuickSettingsDrag() {
    _quickSettingsDragStartedOpen =
        state.quickSettingsVisible || state.quickSettingsDragProgress >= 1.0;
    _quickSettingsDragMoved = false;
    state = state.copyWith(
      quickSettingsDrag: Offset.zero,
      quickSettingsVisible: state.quickSettingsVisible,
      quickSettingsDragActive: true,
    );
  }

  void updateQuickSettingsDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _quickSettingsDragMoved = true;
    final current = state.quickSettingsVisible
        ? ShellMetrics.quickSettingsDragDistance
        : state.quickSettingsDrag.dy;
    final dy = (current + delta.dy)
        .clamp(0.0, ShellMetrics.quickSettingsDragDistance)
        .toDouble();
    if (dy == state.quickSettingsDrag.dy) {
      return;
    }

    state = state.copyWith(
      quickSettingsVisible: false,
      quickSettingsDrag: Offset(0.0, dy),
      quickSettingsDragActive: true,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void endQuickSettingsDrag(double velocity) {
    final drag = state.quickSettingsVisible && !_quickSettingsDragMoved
        ? ShellMetrics.quickSettingsDragDistance
        : state.quickSettingsDrag.dy;
    final flickOpen = velocity >= _quickSettingsFlickVelocity;
    final flickClose = velocity <= -_quickSettingsFlickVelocity;
    final shouldOpen =
        !flickClose &&
        ((_quickSettingsDragStartedOpen && !_quickSettingsDragMoved) ||
            drag >= _quickSettingsOpenDistance ||
            flickOpen);
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    if (shouldOpen) {
      openQuickSettings();
    } else {
      closeQuickSettings();
    }
  }

  void openEdgePanel() {
    if (state.edgePanelVisible &&
        state.edgePanelDrag == Offset.zero &&
        !state.edgePanelDragActive) {
      return;
    }

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    state = state.copyWith(
      edgePanelVisible: true,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
    );
  }

  void closeEdgePanel() {
    if (!state.edgePanelVisible &&
        state.edgePanelDrag == Offset.zero &&
        !state.edgePanelDragActive) {
      return;
    }

    state = state.copyWith(
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void updateEdgePanelViewportScroll(double delta, double maxScroll) {
    if (!state.edgePanelVisible || delta == 0.0 || maxScroll <= 0.0) {
      return;
    }

    final next = (state.edgePanelViewportScroll + delta)
        .clamp(0.0, maxScroll)
        .toDouble();
    if (next == state.edgePanelViewportScroll) {
      return;
    }

    state = state.copyWith(edgePanelViewportScroll: next);
  }

  void startEdgePanelDrag() {
    _edgePanelDragStartedOpen =
        state.edgePanelVisible || state.edgePanelDragProgress >= 1.0;
    _edgePanelDragMoved = false;
    state = state.copyWith(
      edgePanelDrag: Offset.zero,
      edgePanelVisible: state.edgePanelVisible,
      edgePanelDragActive: true,
    );
  }

  void updateEdgePanelDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _edgePanelDragMoved = true;
    final current = state.edgePanelVisible
        ? ShellMetrics.edgePanelDragDistance
        : state.edgePanelDrag.dy;
    final dy = (current - delta.dy)
        .clamp(0.0, ShellMetrics.edgePanelDragDistance)
        .toDouble();
    if (dy == state.edgePanelDrag.dy) {
      return;
    }

    state = state.copyWith(
      edgePanelVisible: false,
      edgePanelDrag: Offset(0.0, dy),
      edgePanelDragActive: true,
      overviewVisible: false,
      gestureDrag: Offset.zero,
      quickSettingsVisible: false,
      quickSettingsDrag: Offset.zero,
      quickSettingsDragActive: false,
    );
  }

  void endEdgePanelDrag(double velocity) {
    final drag = state.edgePanelVisible && !_edgePanelDragMoved
        ? ShellMetrics.edgePanelDragDistance
        : state.edgePanelDrag.dy;
    final flickOpen = velocity <= -_edgePanelFlickVelocity;
    final flickClose = velocity >= _edgePanelFlickVelocity;
    final shouldOpen =
        !flickClose &&
        ((_edgePanelDragStartedOpen && !_edgePanelDragMoved) ||
            drag >= ShellMetrics.edgePanelOpenDistance ||
            flickOpen);
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    if (shouldOpen) {
      openEdgePanel();
    } else {
      closeEdgePanel();
    }
  }

  Offset _visualGestureDrag(Offset rawDrag) {
    return switch (_gestureAxis) {
      _GestureAxis.horizontal => Offset(
        (rawDrag.dx - _gestureLockOrigin.dx)
            .clamp(
              -_gestureHorizontalVisualDistance,
              _gestureHorizontalVisualDistance,
            )
            .toDouble(),
        0.0,
      ),
      _GestureAxis.vertical => Offset(
        0.0,
        rawDrag.dy
            .clamp(-_gestureVisualDistance, _gestureVisualDistance)
            .toDouble(),
      ),
      _GestureAxis.undecided => Offset.zero,
    };
  }

  void _lockGestureAxis() {
    if (_gestureAxis != _GestureAxis.undecided) {
      return;
    }

    if (state.overviewVisible) {
      _gestureAxis = _GestureAxis.vertical;
      return;
    }

    final dx = _rawGestureDrag.dx.abs();
    final dy = _rawGestureDrag.dy.abs();
    if (dx < _gestureAxisLockDistance && dy < _gestureAxisLockDistance) {
      return;
    }

    if (dx > dy * _gestureAxisLockRatio) {
      _gestureAxis = _GestureAxis.horizontal;
      _gestureLockOrigin = _rawGestureDrag;
    } else if (dy > dx * _gestureAxisLockRatio) {
      _gestureAxis = _GestureAxis.vertical;
    }
  }

  void publishInputLayout(
    Size viewSize,
    ShellInteractionSnapshot interactions,
  ) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return;
    }

    final quickSettingsActive =
        state.quickSettingsVisible || state.quickSettingsDragProgress > 0.0;
    if (state.lockLayerVisible) {
      final lockBackgroundWindow = state.primaryWindow;
      _publishInputLayout(
        viewSize: viewSize,
        shellRegions: <Rect>[Offset.zero & viewSize],
        windows: <InputWindowRegion>[
          if (lockBackgroundWindow != null)
            InputWindowRegion(
              window: lockBackgroundWindow,
              rect: Offset.zero & viewSize,
              sourceRect: Offset.zero & viewSize,
              z: 0,
              hitTest: false,
            ),
        ],
        keyboardCapture: true,
        exclusiveShellMode: true,
      );
      return;
    }

    final edgePanelActive =
        state.edgePanelVisible || state.edgePanelDragProgress > 0.0;
    final edgePanelProgress = state.edgePanelDragProgress;
    final edgePanelRect = ShellMetrics.edgePanelRect(
      viewSize,
      edgePanelProgress,
    );
    final contentOffset = edgePanelActive
        ? (edgePanelRect.height - state.edgePanelViewportScroll)
              .clamp(0.0, edgePanelRect.height)
              .toDouble()
        : 0.0;
    final inputBottom = edgePanelActive
        ? edgePanelRect.top.clamp(0.0, viewSize.height).toDouble()
        : viewSize.height;
    final inputWindow = state.inputWindow;
    final canvas = Offset.zero & viewSize;
    final shellRegions = <Rect>[
      if (inputWindow == null ||
          state.overviewVisible ||
          state.launchTransitionActive ||
          quickSettingsActive ||
          interactions.capturesFullScene)
        canvas
      else if (edgePanelActive) ...[
        ShellMetrics.statusRect(viewSize),
        if (edgePanelRect.height > 0.0) edgePanelRect,
        if (state.edgePanelVisible)
          ShellMetrics.edgePanelScrollStripRect(viewSize),
      ] else ...[
        ShellMetrics.statusRect(viewSize),
        ShellMetrics.gestureRect(viewSize),
        ShellMetrics.edgePanelGestureRect(viewSize),
      ],
      for (final region in interactions.childRegions)
        if (!region.intersect(canvas).isEmpty) region.intersect(canvas),
    ];

    final inputRegions = inputWindow == null
        ? const <InputWindowRegion>[]
        : _inputRegionsForWindow(
            window: inputWindow,
            viewSize: viewSize,
            contentOffset: contentOffset,
            inputBottom: inputBottom,
          );

    _publishInputLayout(
      viewSize: viewSize,
      shellRegions: shellRegions,
      windows: inputRegions,
      keyboardCapture: quickSettingsActive || interactions.capturesKeyboard,
      exclusiveShellMode: interactions.compositorExclusive,
    );
  }

  List<InputWindowRegion> _inputRegionsForWindow({
    required DenialWindow window,
    required Size viewSize,
    required double contentOffset,
    required double inputBottom,
  }) {
    final frameTop = -contentOffset;
    final contentTop =
        frameTop + (window.isUserApp ? ShellMetrics.appStatusBarHeight : 0.0);
    final contentBottom = frameTop + viewSize.height;
    final visibleTop = contentTop.clamp(0.0, viewSize.height).toDouble();
    final visibleBottom = contentBottom.clamp(0.0, inputBottom).toDouble();
    if (visibleBottom <= visibleTop) {
      return const <InputWindowRegion>[];
    }

    final rect = Rect.fromLTRB(0, visibleTop, viewSize.width, visibleBottom);
    final sourceRect = Rect.fromLTWH(
      0,
      rect.top - contentTop,
      viewSize.width,
      rect.height,
    );
    final fullContentRect = Rect.fromLTRB(
      0.0,
      contentTop,
      viewSize.width,
      contentBottom,
    );
    final regions = <InputWindowRegion>[];
    for (final popup in window.popupRoots.toList(growable: false).reversed) {
      final popupRect = window.mapSurfaceRect(popup, fullContentRect);
      final clipped = popupRect.intersect(
        Rect.fromLTRB(0.0, visibleTop, viewSize.width, visibleBottom),
      );
      if (clipped.isEmpty ||
          popupRect.width <= 0.0 ||
          popupRect.height <= 0.0) {
        continue;
      }
      final scaleX = popup.surfaceWidth / popupRect.width;
      final scaleY = popup.surfaceHeight / popupRect.height;
      regions.add(
        InputWindowRegion(
          window: window,
          surfaceId: popup.surfaceId,
          rect: clipped,
          sourceRect: Rect.fromLTWH(
            (clipped.left - popupRect.left) * scaleX,
            (clipped.top - popupRect.top) * scaleY,
            clipped.width * scaleX,
            clipped.height * scaleY,
          ),
          z: popup.compositionOrder + 1,
        ),
      );
    }
    regions.add(
      InputWindowRegion(
        window: window,
        // Route through the toplevel root so native hit testing can select an
        // input-capable subsurface rather than the current primary texture.
        surfaceId: window.objectId,
        rect: rect,
        sourceRect: sourceRect,
        z: 0,
      ),
    );
    return regions;
  }

  void _publishInputLayout({
    required Size viewSize,
    required List<Rect> shellRegions,
    required List<InputWindowRegion> windows,
    bool keyboardCapture = false,
    bool exclusiveShellMode = false,
  }) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return;
    }

    final snapshot = InputLayoutSnapshot(
      epoch: _inputLayoutEpoch + 1,
      shellRegions: shellRegions,
      windows: windows,
      visibleSurfaceIds: <int>{
        for (final region in windows) ...region.window.visibleSurfaceIds,
      }.toList(growable: false),
      keyboardCapture: keyboardCapture,
      exclusiveShellMode: exclusiveShellMode,
    );
    if (_lastInputLayoutSnapshot?.hasSameRoutingAs(snapshot) ?? false) {
      return;
    }

    if (!_bridge.publishInputLayout(snapshot)) {
      return;
    }
    _inputLayoutEpoch = snapshot.epoch;
    _lastInputLayoutSnapshot = snapshot;
  }
}

bool _sameWindowSnapshots(List<DenialWindow> a, List<DenialWindow> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

enum _GestureAxis { undecided, horizontal, vertical }
