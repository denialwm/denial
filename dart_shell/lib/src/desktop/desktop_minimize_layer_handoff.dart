import 'dart:async';

import 'package:flutter/foundation.dart';

/// Keeps a minimizing window on the foreground scene plane until it has slid
/// below the desktop, then exposes a separate desktop-widget entrance phase.
///
/// The compositor publishes the minimized state before Flutter's transition
/// starts. Moving the window to the wallpaper plane in that same frame lets a
/// maximized or fullscreen window cover the entire animation. This controller
/// delays the plane handoff until the foreground exit has completed.
class DesktopMinimizeLayerHandoffController {
  DesktopMinimizeLayerHandoffController({
    required this.handoffDelay,
    required this.desktopEntryDuration,
    required this.onChanged,
  }) : assert(!handoffDelay.isNegative),
       assert(!desktopEntryDuration.isNegative);

  final Duration handoffDelay;
  final Duration desktopEntryDuration;
  final VoidCallback onChanged;
  final Map<int, _DesktopMinimizeLayerTransition> _pending =
      <int, _DesktopMinimizeLayerTransition>{};

  bool keepsOnForeground(int objectId) =>
      _pending[objectId]?.phase == _DesktopMinimizeLayerPhase.foreground;

  bool slidesIntoDesktop(int objectId) =>
      _pending[objectId]?.phase == _DesktopMinimizeLayerPhase.desktopEntry;

  void begin(int objectId, {required bool animate}) {
    cancel(objectId);
    if (!animate || handoffDelay == Duration.zero) {
      return;
    }

    final transition = _DesktopMinimizeLayerTransition();
    _pending[objectId] = transition;
    transition.timers.addAll(<Timer>[
      Timer(handoffDelay, () {
        if (!identical(_pending[objectId], transition)) {
          return;
        }
        transition.phase = _DesktopMinimizeLayerPhase.desktopEntry;
        onChanged();
      }),
      Timer(handoffDelay + desktopEntryDuration, () {
        if (identical(_pending[objectId], transition)) {
          _pending.remove(objectId);
          onChanged();
        }
      }),
    ]);
  }

  void cancel(int objectId) {
    final transition = _pending.remove(objectId);
    if (transition == null) {
      return;
    }
    for (final timer in transition.timers) {
      timer.cancel();
    }
  }

  void retainOnly(Set<int> objectIds) {
    final removed = _pending.keys
        .where((objectId) => !objectIds.contains(objectId))
        .toList(growable: false);
    for (final objectId in removed) {
      cancel(objectId);
    }
  }

  void dispose() {
    for (final objectId in _pending.keys.toList(growable: false)) {
      cancel(objectId);
    }
  }
}

enum _DesktopMinimizeLayerPhase { foreground, desktopEntry }

class _DesktopMinimizeLayerTransition {
  _DesktopMinimizeLayerPhase phase = _DesktopMinimizeLayerPhase.foreground;
  final List<Timer> timers = <Timer>[];
}

/// Animates already-minimized windows when their resting placement preference
/// changes between desktop widgets and the off-screen store.
class DesktopMinimizedPlacementTransitionController {
  DesktopMinimizedPlacementTransitionController({
    required this.duration,
    required this.onChanged,
  }) : assert(!duration.isNegative);

  final Duration duration;
  final VoidCallback onChanged;
  final Map<int, _DesktopMinimizedPlacementPhase> _phases =
      <int, _DesktopMinimizedPlacementPhase>{};
  Timer? _timer;

  bool usesDesktopPlacement(int objectId, {required bool configuredDesktop}) {
    return switch (_phases[objectId]) {
      _DesktopMinimizedPlacementPhase.desktopEntry ||
      _DesktopMinimizedPlacementPhase.desktopExit => true,
      _DesktopMinimizedPlacementPhase.offscreenCommitted => false,
      null => configuredDesktop,
    };
  }

  bool entersDesktop(int objectId) =>
      _phases[objectId] == _DesktopMinimizedPlacementPhase.desktopEntry;

  bool exitsDesktop(int objectId) =>
      _phases[objectId] == _DesktopMinimizedPlacementPhase.desktopExit;

  bool commitsOffscreen(int objectId) =>
      _phases[objectId] == _DesktopMinimizedPlacementPhase.offscreenCommitted;

  void begin(
    Iterable<int> objectIds, {
    required bool toDesktop,
    required bool animate,
  }) {
    cancel();
    final ids = objectIds.toSet();
    if (!animate || duration == Duration.zero || ids.isEmpty) {
      return;
    }
    final phase = toDesktop
        ? _DesktopMinimizedPlacementPhase.desktopEntry
        : _DesktopMinimizedPlacementPhase.desktopExit;
    for (final objectId in ids) {
      _phases[objectId] = phase;
    }
    _timer = Timer(duration, () {
      _timer = null;
      if (toDesktop) {
        _phases.clear();
      } else {
        for (final objectId in _phases.keys.toList(growable: false)) {
          _phases[objectId] =
              _DesktopMinimizedPlacementPhase.offscreenCommitted;
        }
      }
      onChanged();
    });
  }

  void retainOnly(Set<int> objectIds) {
    _phases.removeWhere((objectId, _) => !objectIds.contains(objectId));
    if (_phases.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _phases.clear();
  }

  void dispose() => cancel();
}

enum _DesktopMinimizedPlacementPhase {
  desktopEntry,
  desktopExit,
  offscreenCommitted,
}
