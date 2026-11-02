import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../models/denial_window.dart';
import '../models/denial_window_snapshot.dart';
import '../platform/denial_bridge.dart';
import '../platform/denial_bridge_provider.dart';
import 'authentication.dart';
import 'notifier_lifecycle.dart';
import 'shell_state.dart';

final shellControllerProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);

/// Owns the shared native window stream and semantic focus/security operations.
/// Presentation policy belongs to the root plugin, which observes this state.
class ShellController extends Notifier<ShellState>
    with NotifierLifecycle<ShellState> {
  late DenialBridge _bridge;
  late AuthenticationController _authentication;
  bool _refreshInProgress = false;
  bool _refreshQueued = false;
  bool _hasLoadedWindowSnapshot = false;

  @override
  ShellState build() {
    _bridge = ref.watch(denialBridgeProvider);
    _authentication = ref.watch(authenticationProvider.notifier);
    _refreshInProgress = false;
    _refreshQueued = false;
    _hasLoadedWindowSnapshot = false;
    final generation = beginBuildGeneration();
    cancelOnDispose(
      _bridge.windowsChanged.listen(
        (_) => unawaited(_refreshWindows(generation)),
      ),
    );
    cancelOnDispose(
      _bridge.windowSnapshots.listen((snapshot) {
        if (isBuildGenerationActive(generation)) _applyWindowSnapshot(snapshot);
      }),
    );
    cancelOnDispose(
      _bridge.windowActivations.listen((windowId) {
        if (!isBuildGenerationActive(generation)) return;
        final window = state.windowByWindowId(windowId);
        if (window == null || !window.isUserApp) return;
        state = state.copyWith(
          foregroundObjectId: window.objectId,
          activationRevision: state.activationRevision + 1,
        );
      }),
    );
    final authentication = ref.read(authenticationProvider);
    ref.listen<AuthenticationState>(authenticationProvider, (_, next) {
      if (isBuildGenerationActive(generation)) handleAuthenticationState(next);
    });
    scheduleMicrotask(() {
      if (!isBuildGenerationActive(generation)) return;
      handleAuthenticationState(authentication);
      unawaited(_refreshWindows(generation));
    });
    return ShellState.initial(
      locked: ref.watch(startupEnvironmentProvider).flag('DENIAL_START_LOCKED'),
    );
  }

  void lock() => _authentication.lock();
  void requestUnlock() => _authentication.begin();

  /// Turns the screen off as the power button does; the compositor decides
  /// whether that locks.
  void blankDisplays() => _bridge.requestDpmsOff();

  void handleAuthenticationState(AuthenticationState authentication) {
    if (!authentication.synchronized) return;
    if (state.locked != authentication.locked) {
      state = state.copyWith(locked: authentication.locked);
    }
  }

  void closeWindow(DenialWindow window) => _bridge.closeWindow(window);

  void navigateBack(DenialWindow window) => _bridge.navigateBack(window);

  void focusWindow(DenialWindow window) {
    if (!window.isUserApp) return;
    state = state.copyWith(foregroundObjectId: window.objectId);
    _bridge.focusWindow(window);
  }

  /// Clears local focus after a minimize; subsequent native activation wins.
  void releaseWindowFocus(DenialWindow window) {
    if (state.foregroundObjectId == window.objectId) {
      state = state.copyWith(clearForegroundObjectId: true);
    }
  }

  Future<void> _refreshWindows(int generation) async {
    if (!isBuildGenerationActive(generation)) return;
    if (_refreshInProgress) {
      _refreshQueued = true;
      return;
    }
    _refreshInProgress = true;
    try {
      do {
        _refreshQueued = false;
        try {
          final snapshot = await _bridge.listWindows([
            ...state.windows,
            ...state.layerSurfaces,
          ]);
          if (!isBuildGenerationActive(generation)) return;
          _applyWindowSnapshot(snapshot);
        } on Object {
          // An invalidation failure leaves the last known snapshot available.
        }
      } while (_refreshQueued && isBuildGenerationActive(generation));
    } finally {
      if (isBuildGenerationActive(generation)) {
        _refreshInProgress = false;
        if (_refreshQueued) unawaited(_refreshWindows(generation));
      }
    }
  }

  void _applyWindowSnapshot(DenialWindowSnapshot snapshot) {
    if (_hasLoadedWindowSnapshot &&
        snapshot.sequence < state.windowSnapshotSequence) {
      return;
    }
    final windows = <DenialWindow>[];
    final layerSurfaces = <DenialWindow>[];
    var foregroundStillVisible = false;
    for (final window in snapshot.windows) {
      if (window.isLayerShell) {
        layerSurfaces.add(window);
      } else {
        windows.add(window);
        foregroundStillVisible |= window.objectId == state.foregroundObjectId;
      }
    }
    if (_hasLoadedWindowSnapshot &&
        _sameWindows(state.windows, windows) &&
        _sameWindows(state.layerSurfaces, layerSurfaces)) {
      if (snapshot.sequence > state.windowSnapshotSequence) {
        state = state.copyWith(windowSnapshotSequence: snapshot.sequence);
      }
      return;
    }
    _hasLoadedWindowSnapshot = true;
    state = state.copyWith(
      windows: windows,
      layerSurfaces: layerSurfaces,
      windowSnapshotSequence: snapshot.sequence,
      clearForegroundObjectId: !foregroundStillVisible,
    );
  }
}

bool _sameWindows(List<DenialWindow> a, List<DenialWindow> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
