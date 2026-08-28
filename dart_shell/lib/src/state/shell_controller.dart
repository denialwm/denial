import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../input/input_layout.dart';
import '../input/shell_interaction_registry.dart';
import '../models/app_launch_request.dart';
import '../models/denial_window.dart';
import '../models/denial_window_snapshot.dart';
import '../platform/denial_bridge.dart';
import '../services/lock_state_repository.dart';
import 'authentication.dart';
import 'notifier_lifecycle.dart';
import 'shell_input_layout_coordinator.dart';
import 'shell_profile.dart';
import 'shell_state.dart';

part 'shell_controller_helpers.dart';

final denialBridgeProvider = Provider<DenialBridge>((ref) {
  final bridge = DenialBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

final lockStateRepositoryProvider = Provider<LockStateRepository>((ref) {
  final repository = LockStateRepository(
    environment: ref.watch(startupEnvironmentProvider).values,
  );
  ref.onDispose(repository.dispose);
  return repository;
}, isAutoDispose: true);

final shellControllerProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);

class ShellController extends Notifier<ShellState>
    with NotifierLifecycle<ShellState> {
  @override
  ShellState build() {
    _bridge = ref.watch(denialBridgeProvider);
    _lockRepository = ref.watch(lockStateRepositoryProvider);
    _authentication = ref.watch(authenticationProvider.notifier);
    final startLocked = ref
        .watch(startupEnvironmentProvider)
        .flag('DENIA_START_LOCKED');
    _resetBuildFields();
    _automaticSoftwareKeyboard =
        ref.read(shellProfileProvider) == ShellProfile.mobile;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;

    _lockRepository.start(
      onChanged: (locked) {
        if (isBuildGenerationActive(generation)) {
          _handleLockRequestChanged(locked);
        }
      },
    );
    _textInputStateSubscription = _bridge.textInputStates.listen((input) {
      if (isBuildGenerationActive(generation)) {
        _handleTextInputState(input);
      }
    });
    _bridge.start(
      onWindowsChanged: () => unawaited(_refreshWindows(generation)),
      onWindowSnapshot: (snapshot) {
        if (isBuildGenerationActive(generation)) {
          _applyWindowSnapshot(snapshot);
        }
      },
      onWindowActivated: (windowId) {
        if (isBuildGenerationActive(generation)) {
          _handleNativeWindowActivated(windowId);
        }
      },
    );
    final authentication = ref.read(authenticationProvider);
    ref.listen<AuthenticationState>(authenticationProvider, (_, next) {
      if (isBuildGenerationActive(generation)) {
        handleAuthenticationState(next);
      }
    });
    ref.onDispose(() {
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      _automaticSoftwareKeyboardCloseTimer = null;
      _launchRequestTimer?.cancel();
      _launchRequestTimer = null;
      unawaited(_textInputStateSubscription?.cancel());
      _textInputStateSubscription = null;
    });
    scheduleMicrotask(() {
      if (!isBuildGenerationActive(generation)) {
        return;
      }
      handleAuthenticationState(authentication);
      unawaited(_refreshWindows(generation));
    });
    return ShellState.initial(locked: startLocked);
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
  static const Duration _automaticSoftwareKeyboardCloseGrace = Duration(
    milliseconds: 24,
  );

  late DenialBridge _bridge;
  late LockStateRepository _lockRepository;
  late AuthenticationController _authentication;
  late int _buildGeneration;
  late ShellInputLayoutCoordinator _inputLayoutCoordinator;
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
  bool _automaticSoftwareKeyboard = false;
  final Set<String> _legacyTextInputAppIds = <String>{};
  final Set<String> _backgroundLaunchAppIds = <String>{};
  Timer? _automaticSoftwareKeyboardCloseTimer;
  StreamSubscription<DenialTextInputState>? _textInputStateSubscription;

  void _resetBuildFields() {
    _automaticSoftwareKeyboardCloseTimer?.cancel();
    _automaticSoftwareKeyboardCloseTimer = null;
    unawaited(_textInputStateSubscription?.cancel());
    _textInputStateSubscription = null;
    _inputLayoutCoordinator = ShellInputLayoutCoordinator(_bridge);
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    _refreshInProgress = false;
    _refreshQueued = false;
    _hasLoadedWindowSnapshot = false;
    _nextLaunchRequestId = 1;
    _launchRequestTimer = null;
    _lastMirroredNativeLock = null;
    _legacyTextInputAppIds.clear();
    _backgroundLaunchAppIds.clear();
  }

  void _handleTextInputState(DenialTextInputState input) {
    if (!_automaticSoftwareKeyboard) {
      return;
    }
    if (input.inputPanelVisible) {
      final foregroundAppId = AppLaunchRequest.normalizeAppId(
        state.foregroundWindow?.appId ?? '',
      );
      if (input.legacy && !_legacyTextInputAppIds.contains(foregroundAppId)) {
        closeEdgePanel();
        return;
      }
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      _automaticSoftwareKeyboardCloseTimer = null;
      openEdgePanel();
    } else {
      // Flutter retires the old TextInputClient just before registering the
      // next one during a field-to-field focus transfer. Preserve the panel
      // across that short protocol gap; a replacement editor cancels this
      // close before any visible keyboard motion begins.
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      final generation = _buildGeneration;
      _automaticSoftwareKeyboardCloseTimer = Timer(
        _automaticSoftwareKeyboardCloseGrace,
        () {
          _automaticSoftwareKeyboardCloseTimer = null;
          if (isBuildGenerationActive(generation)) {
            closeEdgePanel();
          }
        },
      );
    }
  }

  void registerLegacyTextInputAppIds(Iterable<String> appIds) {
    _legacyTextInputAppIds.addAll(
      appIds
          .map(AppLaunchRequest.normalizeAppId)
          .where((identity) => identity.isNotEmpty),
    );
  }

  void lock() {
    _authentication.lock();
  }

  /// Secures the session first, then asks the compositor to blank its outputs.
  /// Both commands use Denial's native channels; no external power daemon is
  /// involved.
  void lockAndBlankDisplays() {
    lock();
    _bridge.requestDpmsOff();
  }

  void requestUnlock() {
    _authentication.begin();
  }

  void completeUnlockTransition() {
    if (state.locked || !state.lockLayerVisible) {
      return;
    }

    _inputLayoutCoordinator.invalidate();
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

  Future<void> _refreshWindows(int generation) async {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
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
          if (!isBuildGenerationActive(generation)) {
            return;
          }
          _applyWindowSnapshot(snapshot);
        } catch (_) {
          // Keep the last known snapshot. Window changes are invalidation events.
        }
      } while (_refreshQueued && isBuildGenerationActive(generation));
    } finally {
      if (isBuildGenerationActive(generation)) {
        _refreshInProgress = false;
        if (_refreshQueued) {
          unawaited(_refreshWindows(generation));
        }
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
        if (window.objectId == boundObjectId && request.matchesWindow(window)) {
          return window;
        }
      }
    }

    for (final window in windows) {
      if (request.matchesWindow(window)) {
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
    return _beginLauncherTransition(
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: expectedAppIds,
    );
  }

  /// Focuses an already-open application through the same coherent launcher
  /// transition used for a newly-created application window.
  int? activateAppFromLauncher({
    required DenialWindow window,
    required String appName,
    required String? iconPath,
  }) {
    if (!window.isUserApp) {
      return null;
    }
    return _beginLauncherTransition(
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: <String>[window.appId],
      targetWindow: window,
    );
  }

  int? _beginLauncherTransition({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
    DenialWindow? targetWindow,
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
      targetObjectId: targetWindow?.objectId,
    );

    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _launchRequestTimer?.cancel();
    final generation = _buildGeneration;
    _launchRequestTimer = Timer(_launchRequestTimeout, () {
      if (isBuildGenerationActive(generation)) {
        failAppLaunch(requestId);
      }
    });

    state = state.copyWith(
      launchRequest: request,
      foregroundObjectId: targetWindow?.objectId,
      launchingObjectId: targetWindow?.objectId,
      clearLaunchingObjectId: targetWindow == null,
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
    if (targetWindow != null) {
      _backgroundLaunchAppIds.remove(
        AppLaunchRequest.normalizeAppId(targetWindow.appId),
      );
      _bridge.focusWindow(targetWindow);
    }
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
    final launchRequest = state.launchRequest;
    if (launchRequest != null) {
      _launchRequestTimer?.cancel();
      _launchRequestTimer = null;
      _backgroundLaunchAppIds.addAll(launchRequest.expectedAppIds);
      state = state.copyWith(
        clearLaunchRequest: true,
        clearLaunchingObjectId: true,
        clearForegroundObjectId: true,
        homeTransitionActive: false,
        overviewVisible: false,
        gestureDrag: Offset.zero,
        quickSettingsVisible: false,
        quickSettingsDrag: Offset.zero,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
      return;
    }
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

    _backgroundLaunchAppIds.remove(
      AppLaunchRequest.normalizeAppId(window.appId),
    );
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
        final appId = AppLaunchRequest.normalizeAppId(window.appId);
        if (_backgroundLaunchAppIds.remove(appId)) {
          return;
        }
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
    _inputLayoutCoordinator.publish(
      state: state,
      viewSize: viewSize,
      interactions: interactions,
    );
  }
}
