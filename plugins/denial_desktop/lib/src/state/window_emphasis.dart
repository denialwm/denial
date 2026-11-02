import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/desktop_workspace.dart';
import 'desktop_visibility.dart';
import 'desktop_window_switcher.dart';

import 'package:denial_flutter_sdk/state.dart';

import 'window_emphasis_requests.dart';

/// Transient presentation only: never changes focus, stacking or minimization.
final windowEmphasisProvider =
    NotifierProvider<WindowEmphasis, WindowEmphasisTarget?>(WindowEmphasis.new);

/// Popups use the owning application ID, so the same scope applies to them.
final windowDeemphasizedProvider = Provider.autoDispose.family<bool, int>((
  ref,
  id,
) {
  final target = ref.watch(windowEmphasisProvider);
  if (target == null) return false;
  return ref.watch(
    referenceShellProvider.select((shell) {
      final window = shell.desk.openAppWindowsByObjectId[id];
      return window != null &&
          windowIsDeemphasized(
            target,
            windowId: id,
            monitorId: window.monitorId,
            workspaceId: window.workspaceId,
            pinned: window.pinned,
          );
    }),
  );
});

class WindowEmphasis extends Notifier<WindowEmphasisTarget?> {
  late WindowEmphasisRequests _requests;

  @override
  WindowEmphasisTarget? build() {
    _requests = WindowEmphasisRequests((target) {
      if (ref.mounted) state = target;
    });
    final activations = ref.read(denialBridgeProvider).windowActivations.listen(
      (_) {
        if (ref.mounted) clear();
      },
    );
    ref.onDispose(() => unawaited(activations.cancel()));
    ref.listen(referenceShellProvider, (previous, next) {
      final target = _requests.target;
      if (target == null) return;
      final window = next.desk.openAppWindowsByObjectId[target.windowId];
      final previousWindow =
          previous?.desk.openAppWindowsByObjectId[target.windowId];
      if (next.locked ||
          window == null ||
          window.monitorId != target.monitorId ||
          (previousWindow != null &&
              previousWindow.workspaceId != window.workspaceId) ||
          (previous != null &&
              (next.deskForegroundObjectId != previous.deskForegroundObjectId ||
                  next.launchRequest != previous.launchRequest))) {
        clear();
      }
    });
    ref.listen(desktopWorkspaceProvider, (_, next) {
      final target = _requests.target;
      if (target == null) return;
      final workspace = next.workspacesEnabled
          ? next.activeWorkspaceFor(target.monitorId)
          : null;
      if (next.overviewActive || workspace != target.workspaceId) {
        clear();
      }
    });
    ref.listen(desktopWindowSwitcherProvider, (_, next) {
      if (next != null) clear();
    });
    ref.listen(desktopVisibleProvider, (_, visible) {
      if (visible) clear();
    });
    return null;
  }

  VoidCallback begin(int windowId, {required int monitorId}) {
    final shell = ref.read(referenceShellProvider);
    final desktop = ref.read(desktopWorkspaceProvider);
    final window = shell.desk.openAppWindowsByObjectId[windowId];
    if (shell.locked ||
        window == null ||
        window.monitorId != monitorId ||
        ref.read(desktopVisibleProvider) ||
        desktop.overviewActive ||
        ref.read(desktopWindowSwitcherProvider) != null) {
      return () {};
    }
    final release = _requests.begin((
      windowId: windowId,
      monitorId: monitorId,
      workspaceId: desktop.workspacesEnabled
          ? desktop.activeWorkspaceFor(monitorId)
          : null,
    ));
    // Owners can be disposed while Flutter is rebuilding an overlay. Release
    // after that build; ownership prevents this from clearing a newer request.
    return () => scheduleMicrotask(() {
      if (ref.mounted) release();
    });
  }

  void clear() => _requests.clear();
}
