import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
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

enum DesktopLivePlacementUpdateResult { applied, inactive, stale, incompatible }

class _DesktopLivePlacementSession {
  _DesktopLivePlacementSession(this.baselineContentRect, this.latestSequence);

  final Rect baselineContentRect;
  int latestSequence;
  DenialWindowPlacementEvent? latestEvent;
}

/// Publishes pure native move deltas without invalidating workspace state.
///
/// Rust owns input routing and window geometry for the duration of its grab.
/// Flutter therefore only needs a retained paint translation between the
/// authoritative begin and end packets. Resize remains on the workspace path
/// because it changes layout and texture sampling.
@visibleForTesting
class DesktopLiveWindowPlacements {
  final Map<int, ValueNotifier<Offset>> _translations =
      <int, ValueNotifier<Offset>>{};
  final Map<int, _DesktopLivePlacementSession> _sessions =
      <int, _DesktopLivePlacementSession>{};

  ValueListenable<Offset> translationFor(int objectId) {
    return _translations.putIfAbsent(
      objectId,
      () => ValueNotifier<Offset>(Offset.zero),
    );
  }

  void start(int objectId, DenialWindowPlacementEvent event) {
    assert(event.change == DenialWindowPlacementChange.move);
    _sessions[objectId] = _DesktopLivePlacementSession(
      event.contentRect,
      event.sequence,
    );
    _setTranslation(objectId, Offset.zero);
  }

  bool isStaleBoundary(int objectId, int sequence) {
    final session = _sessions[objectId];
    return session != null && sequence <= session.latestSequence;
  }

  DesktopLivePlacementUpdateResult update(
    int objectId,
    DenialWindowPlacementEvent event,
  ) {
    assert(event.phase == DenialWindowPlacementPhase.update);
    final session = _sessions[objectId];
    if (session == null) {
      return DesktopLivePlacementUpdateResult.inactive;
    }
    if (event.sequence <= session.latestSequence) {
      return DesktopLivePlacementUpdateResult.stale;
    }
    if (event.change != DenialWindowPlacementChange.move ||
        event.contentRect.size != session.baselineContentRect.size) {
      return DesktopLivePlacementUpdateResult.incompatible;
    }
    session
      ..latestSequence = event.sequence
      ..latestEvent = event;
    _setTranslation(
      objectId,
      event.contentRect.topLeft - session.baselineContentRect.topLeft,
    );
    return DesktopLivePlacementUpdateResult.applied;
  }

  /// Ends a live session and returns its last uncommitted placement, if any.
  DenialWindowPlacementEvent? finish(int objectId) {
    final event = _sessions.remove(objectId)?.latestEvent;
    _setTranslation(objectId, Offset.zero);
    return event;
  }

  void clear() {
    _sessions.clear();
    for (final translation in _translations.values) {
      translation.value = Offset.zero;
    }
  }

  void dispose() {
    for (final translation in _translations.values) {
      translation.dispose();
    }
    _translations.clear();
    _sessions.clear();
  }

  void _setTranslation(int objectId, Offset value) {
    final translation = _translations.putIfAbsent(
      objectId,
      () => ValueNotifier<Offset>(Offset.zero),
    );
    translation.value = value;
  }
}

final desktopLiveWindowPlacementsProvider =
    Provider<DesktopLiveWindowPlacements>((ref) {
      final placements = DesktopLiveWindowPlacements();
      ref.onDispose(placements.dispose);
      return placements;
    });

// Own the native-event subscription outside the widget tree's rendering
// logic. Semantic boundaries and resizes reduce into DesktopWindowPlacement;
// pure in-progress moves update a retained paint translation instead.
final desktopWindowCoordinatorProvider = Provider<void>((ref) {
  ref.read(shellControllerProvider);
  final livePlacements = ref.read(desktopLiveWindowPlacementsProvider);
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

  int? objectIdFor(DenialWindowEvent event) {
    final target = ref
        .read(shellControllerProvider)
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
        // Begin and end packets both contain authoritative geometry. They
        // supersede an update that has not reached a frame yet.
        placementFrameBatch.remove(event.windowId);
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
    livePlacements.clear();
    unawaited(subscription.cancel());
  });
});

bool _reduceWindowEvent(Ref ref, DenialWindowEvent event) {
  final shell = ref.read(shellControllerProvider);
  final target = shell.windowByWindowId(event.windowId);
  if (target == null || !target.isUserApp) {
    return false;
  }

  final workspace = ref.read(desktopWorkspaceProvider.notifier);
  switch (event) {
    case DenialWindowPlacementEvent():
      if (event.phase == DenialWindowPlacementPhase.begin) {
        ref.read(shellControllerProvider.notifier).focusWindow(target);
      }
      return workspace.applyNativePlacement(target.objectId, event);
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
      return true;
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
