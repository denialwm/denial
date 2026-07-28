import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/denial_window_event.dart';
import '../models/display_layout.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import 'desktop_workspace.dart';

const int _maxDeferredWindowEvents = 4096;

@visibleForTesting
class DesktopWindowEventBacklog {
  DesktopWindowEventBacklog({this.capacity = _maxDeferredWindowEvents})
    : assert(capacity >= 0);

  final int capacity;
  final ListQueue<DenialWindowEvent> _events = ListQueue<DenialWindowEvent>();

  int get length => _events.length;

  void add(DenialWindowEvent event) {
    if (capacity <= 0) {
      return;
    }
    if (_events.length >= capacity) {
      _events.removeFirst();
    }
    _events.addLast(event);
  }

  List<DenialWindowEvent> takeReady(
    bool Function(DenialWindowEvent event) isReady,
  ) {
    final ready = <DenialWindowEvent>[];
    final pending = _events.length;
    for (var index = 0; index < pending; index += 1) {
      final event = _events.removeFirst();
      if (isReady(event)) {
        ready.add(event);
      } else {
        _events.addLast(event);
      }
    }
    return ready;
  }
}

/// Retains only the newest in-progress native placement for each window.
///
/// Pointer sampling can run faster than Flutter's current frame rate,
/// especially in a debug build. Publishing every intermediate coordinate to
/// provider state creates work that can never be displayed. Begin/end phases
/// remain immediate; update phases are sampled once at the next frame.
@visibleForTesting
class DesktopWindowPlacementFrameBatch {
  final Map<int, DenialWindowPlacementEvent> _updates =
      <int, DenialWindowPlacementEvent>{};

  int get length => _updates.length;

  void add(DenialWindowPlacementEvent event) {
    assert(event.phase == DenialWindowPlacementPhase.update);
    final previous = _updates[event.windowId];
    if (previous == null || event.sequence > previous.sequence) {
      _updates[event.windowId] = event;
    }
  }

  DenialWindowPlacementEvent? remove(int windowId) => _updates.remove(windowId);

  List<DenialWindowPlacementEvent> takeAll() {
    final updates = _updates.values.toList(growable: false)
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    _updates.clear();
    return updates;
  }

  void clear() => _updates.clear();
}

// Own the native-event subscription outside the widget tree's rendering
// logic. Every native placement is reduced into DesktopWindowPlacement before
// UI consumers such as overview resolve monitor membership.
final desktopWindowCoordinatorProvider = Provider<void>((ref) {
  ref.read(shellControllerProvider);
  final backlog = DesktopWindowEventBacklog();
  final placementFrameBatch = DesktopWindowPlacementFrameBatch();
  var drainingBacklog = false;
  int? placementFrameCallbackId;
  var disposed = false;

  bool eventIsReady(DenialWindowEvent event) {
    final target = ref
        .read(shellControllerProvider)
        .windowByWindowId(event.windowId);
    if (target == null) {
      return false;
    }
    return !target.isUserApp ||
        ref
            .read(desktopWorkspaceProvider)
            .placements
            .containsKey(target.objectId);
  }

  void flushPlacementFrame(Duration _) {
    placementFrameCallbackId = null;
    if (disposed) {
      placementFrameBatch.clear();
      return;
    }
    for (final event in placementFrameBatch.takeAll()) {
      _reduceWindowEvent(ref, event);
    }
  }

  void schedulePlacementUpdate(DenialWindowPlacementEvent event) {
    placementFrameBatch.add(event);
    placementFrameCallbackId ??= SchedulerBinding.instance
        .scheduleFrameCallback(flushPlacementFrame);
  }

  void dispatchWindowEvent(DenialWindowEvent event) {
    switch (event) {
      case DenialWindowPlacementEvent(phase: DenialWindowPlacementPhase.update):
        schedulePlacementUpdate(event);
      case DenialWindowPlacementEvent():
        // Begin and end packets both contain authoritative geometry. They
        // supersede an update that has not reached a frame yet.
        placementFrameBatch.remove(event.windowId);
        _reduceWindowEvent(ref, event);
      case DenialWindowActionEvent():
        // Preserve per-window ordering when an action follows a placement in
        // the same event-loop turn.
        final pending = placementFrameBatch.remove(event.windowId);
        if (pending != null) {
          _reduceWindowEvent(ref, pending);
        }
        _reduceWindowEvent(ref, event);
    }
  }

  void drainDeferredBacklog() {
    if (drainingBacklog) {
      return;
    }
    drainingBacklog = true;
    try {
      for (final event in backlog.takeReady(eventIsReady)) {
        dispatchWindowEvent(event);
      }
    } finally {
      drainingBacklog = false;
    }
  }

  void handleWindowEvent(DenialWindowEvent event) {
    // Native can publish placement/state immediately after the metadata
    // snapshot, one Flutter frame before DesktopWorkspace has materialized
    // the corresponding placement. Retain that ordered prefix instead of
    // interpreting restored geometry as a brand-new maximize operation.
    backlog.add(event);
    drainDeferredBacklog();
  }

  ref.listen(
    shellControllerProvider,
    (previous, next) => drainDeferredBacklog(),
  );
  ref.listen(
    desktopWorkspaceProvider,
    (previous, next) => drainDeferredBacklog(),
  );
  ref.listen<DisplayLayout?>(
    displayLayoutProvider,
    (previous, next) => ref
        .read(desktopWorkspaceProvider.notifier)
        .syncWorkAreas(next?.workAreasByMonitor() ?? const <int, Rect>{}),
    fireImmediately: true,
  );
  final subscription = ref
      .read(denialBridgeProvider)
      .windowEvents
      .listen(handleWindowEvent);
  ref.onDispose(() {
    disposed = true;
    if (placementFrameCallbackId case final callbackId?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    placementFrameBatch.clear();
    unawaited(subscription.cancel());
  });
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
          ref.read(shellControllerProvider.notifier).releaseWindowFocus(target);
        case DenialWindowAction.maximize:
          workspace.maximize(
            target.objectId,
            bounds: _outputBounds(ref, target.objectId, workArea: true),
          );
        case DenialWindowAction.restore:
          workspace.restore(target.objectId);
        case DenialWindowAction.toggleMaximize:
          workspace.toggleMaximized(
            target.objectId,
            bounds: _outputBounds(ref, target.objectId, workArea: true),
          );
        case DenialWindowAction.toggleFullscreen:
          // True fullscreen deliberately ignores the system-bar work area and
          // covers the complete output.
          workspace.toggleFullscreen(
            target.objectId,
            bounds: _outputBounds(ref, target.objectId, workArea: false),
          );
      }
  }
}

Rect _outputBounds(Ref ref, int objectId, {required bool workArea}) {
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

  Rect resolve(DisplayOutput output) {
    final rect = workArea
        ? displayLayout!.workAreaOf(output)
        : output.logicalRect;
    return rect.intersect(canvas);
  }

  for (final output in outputs) {
    if (output.monitorId == placement.monitorId) {
      final bounds = resolve(output);
      if (!bounds.isEmpty) {
        return bounds;
      }
    }
  }

  for (final output in outputs) {
    if (output.logicalRect.contains(placement.frame.center)) {
      final bounds = resolve(output);
      if (!bounds.isEmpty) {
        return bounds;
      }
    }
  }

  return canvas;
}
