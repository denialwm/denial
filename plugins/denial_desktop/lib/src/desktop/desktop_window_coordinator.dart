import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'package:denial_flutter_sdk/lifecycle.dart' show DeferredEventDispatcher;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'desktop_workspace.dart';
import 'desktop_live_window_placements.dart';
import '../state/phone_desk.dart';

export 'desktop_live_window_placements.dart';

const int _maxDeferredWindowEvents = 4096;

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
// logic. Semantic boundaries and resizes reduce into DesktopWindowPlacement;
// pure in-progress moves update a retained paint translation instead.
final desktopWindowCoordinatorProvider = Provider<void>((ref) {
  ref.read(referenceShellProvider);
  final livePlacements = ref.read(desktopLiveWindowPlacementsProvider);
  final placementFrameBatch = DesktopWindowPlacementFrameBatch();
  int? placementFrameCallbackId;
  var disposed = false;

  bool eventIsReady(DenialWindowEvent event) {
    final target = ref
        .read(referenceShellProvider)
        .desk
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

  int? objectIdFor(DenialWindowEvent event) {
    final target = ref
        .read(referenceShellProvider)
        .desk
        .windowByWindowId(event.windowId);
    return target?.isUserApp == true ? target!.objectId : null;
  }

  void processPlacementUpdate(DenialWindowPlacementEvent event) {
    final objectId = objectIdFor(event);
    if (objectId == null) {
      _reduceWindowEvent(ref, event);
      return;
    }
    void reduceAndMaybeStart() {
      final accepted = _reduceWindowEvent(ref, event);
      if (accepted && event.change == DenialWindowPlacementChange.move) {
        // A defensive update-without-begin still gets the fast path from its
        // next sample onward after this packet establishes a committed anchor.
        livePlacements.start(objectId, event);
      }
    }

    switch (livePlacements.update(objectId, event)) {
      case DesktopLivePlacementUpdateResult.applied ||
          DesktopLivePlacementUpdateResult.stale:
        return;
      case DesktopLivePlacementUpdateResult.incompatible:
        final pending = livePlacements.finish(objectId);
        if (pending != null) {
          _reduceWindowEvent(ref, pending);
        }
        reduceAndMaybeStart();
        return;
      case DesktopLivePlacementUpdateResult.inactive:
        reduceAndMaybeStart();
        return;
    }
  }

  void processPlacementBoundary(DenialWindowPlacementEvent event) {
    final objectId = objectIdFor(event);
    if (objectId != null &&
        livePlacements.isStaleBoundary(objectId, event.sequence)) {
      return;
    }
    final accepted = _reduceWindowEvent(ref, event);
    if (!accepted || objectId == null) {
      return;
    }
    if (event.phase == DenialWindowPlacementPhase.begin &&
        event.change == DenialWindowPlacementChange.move) {
      livePlacements.start(objectId, event);
    } else {
      livePlacements.finish(objectId);
    }
  }

  void commitLivePlacementBeforeAction(DenialWindowActionEvent event) {
    final objectId = objectIdFor(event);
    if (objectId == null) {
      return;
    }
    final pending = livePlacements.finish(objectId);
    if (pending != null) {
      _reduceWindowEvent(ref, pending);
    }
  }

  void flushPlacementFrame(Duration _) {
    placementFrameCallbackId = null;
    if (disposed) {
      placementFrameBatch.clear();
      return;
    }
    for (final event in placementFrameBatch.takeAll()) {
      processPlacementUpdate(event);
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
        // Preserve the last sampled pointer rectangle before an end packet
        // replaces it with a layout-owned tile. The release handoff uses this
        // exact visual point as the settle animation's origin.
        final pending = placementFrameBatch.remove(event.windowId);
        if (pending != null && event.phase == DenialWindowPlacementPhase.end) {
          processPlacementUpdate(pending);
        }
        processPlacementBoundary(event);
      case DenialWindowActionEvent():
        // Preserve per-window ordering when an action follows a placement in
        // the same event-loop turn.
        final pending = placementFrameBatch.remove(event.windowId);
        if (pending != null) {
          processPlacementUpdate(pending);
        }
        commitLivePlacementBeforeAction(event);
        _reduceWindowEvent(ref, event);
    }
  }

  // Native may send placement before the corresponding workspace exists.
  // The dispatcher retains those events and skips queue allocation once ready.
  final events = DeferredEventDispatcher<DenialWindowEvent>(
    capacity: _maxDeferredWindowEvents,
    isReady: eventIsReady,
    dispatch: dispatchWindowEvent,
  );

  ref.listen(referenceShellProvider, (previous, next) => events.drain());
  ref.listen(desktopWorkspaceProvider, (previous, next) => events.drain());
  ref.listen<DisplayLayout?>(
    deskDisplayLayoutProvider,
    (previous, next) => ref
        .read(desktopWorkspaceProvider.notifier)
        .syncWorkAreas(next?.workAreasByMonitor() ?? const <int, Rect>{}),
    fireImmediately: true,
  );
  final subscription = ref
      .read(denialBridgeProvider)
      .windowEvents
      .listen(events.add);
  ref.onDispose(() {
    disposed = true;
    if (placementFrameCallbackId case final callbackId?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    events.clear();
    placementFrameBatch.clear();
    livePlacements.clear();
    unawaited(subscription.cancel());
  });
});

bool _reduceWindowEvent(Ref ref, DenialWindowEvent event) {
  final shell = ref.read(referenceShellProvider);
  final target = shell.desk.windowByWindowId(event.windowId);
  if (target == null || !target.isUserApp) {
    return false;
  }

  final workspace = ref.read(desktopWorkspaceProvider.notifier);
  switch (event) {
    case DenialWindowPlacementEvent():
      if (event.phase == DenialWindowPlacementPhase.begin &&
          event.change != DenialWindowPlacementChange.layoutPreview) {
        ref.read(referenceShellProvider.notifier).focusWindow(target);
      }
      return workspace.applyNativePlacement(target.objectId, event);
    case DenialWindowActionEvent():
      // Managed XDG and Xwayland windows have already completed this action
      // in Rust. Their next snapshot/placement is the sole geometry and state
      // authority. Replaying the action in Flutter would manufacture a second
      // restore rectangle; for a client which started fullscreen there is no
      // valid pre-fullscreen rectangle, so that speculation can reject every
      // later layout split until an unrelated manual resize clears it.
      if (!target.isLocalFlutter) {
        if (event.action == DenialWindowAction.minimize) {
          ref.read(referenceShellProvider.notifier).releaseWindowFocus(target);
        }
        return true;
      }
      workspace.applyFlutterOwnedWindowAction(
        target,
        event.action,
        maximizeBounds: _outputBounds(ref, target.objectId, workArea: true),
        fullscreenBounds: _outputBounds(ref, target.objectId, workArea: false),
      );
      if (event.action == DenialWindowAction.minimize) {
        ref.read(referenceShellProvider.notifier).releaseWindowFocus(target);
      }
      return true;
  }
}

Rect _outputBounds(Ref ref, int objectId, {required bool workArea}) {
  final workspace = ref.read(desktopWorkspaceProvider);
  final displayLayout = ref.read(deskDisplayLayoutProvider);
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

  // A scrolling tile or a client-supplied virtual-desktop rectangle can put
  // the frame center outside every output. Select the strongest physical
  // overlap (then the nearest output) instead of treating the whole Flutter
  // canvas as a monitor.
  DisplayOutput? bestOutput;
  var bestOverlap = -1.0;
  var bestDistance = double.infinity;
  for (final output in outputs) {
    final bounds = resolve(output);
    if (bounds.isEmpty) {
      continue;
    }
    final overlap = bounds.intersect(placement.frame);
    final overlapArea = overlap.isEmpty ? 0.0 : overlap.width * overlap.height;
    final dx =
        placement.frame.center.dx.clamp(bounds.left, bounds.right) -
        placement.frame.center.dx;
    final dy =
        placement.frame.center.dy.clamp(bounds.top, bounds.bottom) -
        placement.frame.center.dy;
    final distance = dx * dx + dy * dy;
    if (overlapArea > bestOverlap ||
        (overlapArea == bestOverlap && distance < bestDistance)) {
      bestOutput = output;
      bestOverlap = overlapArea;
      bestDistance = distance;
    }
  }
  if (bestOutput != null) {
    return resolve(bestOutput);
  }

  return canvas;
}
