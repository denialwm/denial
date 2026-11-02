import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/desktop_workspace.dart';
import 'desktop_window_switcher.dart';

import 'package:denial_flutter_sdk/state.dart';

/// A temporary presentation mode, not a second source of native window state.
/// Windows retain their geometry, stacking, and original minimized state.
final desktopVisibleProvider = NotifierProvider<DesktopVisibility, bool>(
  DesktopVisibility.new,
);

class DesktopVisibility extends Notifier<bool> {
  @override
  bool build() {
    final activations = ref.read(denialBridgeProvider).windowActivations.listen(
      (_) {
        if (ref.mounted) restore();
      },
    );
    ref.onDispose(() => unawaited(activations.cancel()));
    ref.listen(referenceShellProvider, (previous, next) {
      if (!state || previous == null) return;
      if (next.locked ||
          next.deskForegroundObjectId != previous.deskForegroundObjectId ||
          next.launchRequest != previous.launchRequest ||
          next.desk.openAppWindows.any(
            (window) => !previous.desk.openAppWindowsByObjectId.containsKey(
              window.objectId,
            ),
          )) {
        restore();
      }
    });
    ref.listen(desktopWindowSwitcherProvider, (_, next) {
      if (next != null) restore();
    });
    ref.listen(desktopWorkspaceProvider, (previous, next) {
      if (next.overviewActive ||
          (previous != null &&
              !mapEquals(previous.activeWorkspaces, next.activeWorkspaces))) {
        restore();
      }
    });
    return false;
  }

  void toggle() {
    if (ref.read(referenceShellProvider).locked) return;
    // Close overview before entering the desktop presentation.
    if (!state) ref.read(desktopWorkspaceProvider.notifier).closeOverview();
    state = !state;
  }

  void restore() {
    if (state) state = false;
  }
}
