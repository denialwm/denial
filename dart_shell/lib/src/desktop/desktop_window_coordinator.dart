import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/denial_window_event.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import 'desktop_workspace.dart';

// Own the native-event subscription outside the widget tree's rendering
// logic. Every native placement is reduced into DesktopWindowPlacement before
// UI consumers such as overview resolve monitor membership.
final desktopWindowCoordinatorProvider = Provider<void>((ref) {
  ref.read(shellControllerProvider);
  final subscription = ref
      .read(denialBridgeProvider)
      .windowEvents
      .listen((event) => _reduceWindowEvent(ref, event));
  ref.onDispose(() => unawaited(subscription.cancel()));
});

void _reduceWindowEvent(Ref ref, DenialWindowEvent event) {
  final shell = ref.read(shellControllerProvider);
  final target = shell.windowByWindowId(event.windowId);
  if (target == null || !target.isUserApp) {
    return;
  }

  final workspace = ref.read(desktopWorkspaceProvider.notifier);
  switch (event) {
    case DenialWindowPlacementEvent():
      if (event.phase == DenialWindowPlacementPhase.begin) {
        ref.read(shellControllerProvider.notifier).focusWindow(target);
      }
      workspace.applyNativePlacement(target.objectId, event);
    case DenialWindowActionEvent():
      switch (event.action) {
        case DenialWindowAction.minimize:
          workspace.minimize(target.objectId);
        case DenialWindowAction.maximize:
          workspace.maximize(
            target.objectId,
            bounds: _outputBounds(ref, target.objectId),
          );
        case DenialWindowAction.restore:
          workspace.restore(target.objectId);
        case DenialWindowAction.toggleMaximize:
          workspace.toggleMaximized(
            target.objectId,
            bounds: _outputBounds(ref, target.objectId),
          );
        case DenialWindowAction.toggleFullscreen:
          workspace.toggleFullscreen(
            target.objectId,
            bounds: _outputBounds(ref, target.objectId),
          );
      }
  }
}

Rect _outputBounds(Ref ref, int objectId) {
  final workspace = ref.read(desktopWorkspaceProvider);
  final displayLayout = ref.read(displayLayoutProvider);
  final viewSize = workspace.viewSize.isEmpty
      ? displayLayout?.logicalSize ?? Size.zero
      : workspace.viewSize;
  final canvas = Offset.zero & viewSize;
  final placement = workspace.placements[objectId];
  final outputs = displayLayout?.outputs;
  if (placement == null || outputs == null || outputs.isEmpty) {
    return canvas;
  }

  for (final output in outputs) {
    if (output.monitorId == placement.monitorId) {
      final bounds = output.logicalRect.intersect(canvas);
      if (!bounds.isEmpty) {
        return bounds;
      }
    }
  }

  for (final output in outputs) {
    if (output.logicalRect.contains(placement.frame.center)) {
      final bounds = output.logicalRect.intersect(canvas);
      if (!bounds.isEmpty) {
        return bounds;
      }
    }
  }

  return canvas;
}
