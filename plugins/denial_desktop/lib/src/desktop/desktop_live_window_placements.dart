import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/models.dart';

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
class DesktopLiveWindowPlacements {
  final Map<int, ValueNotifier<Offset>> _translations =
      <int, ValueNotifier<Offset>>{};
  final Map<int, _DesktopLivePlacementSession> _sessions =
      <int, _DesktopLivePlacementSession>{};
  final Map<int, Offset> _settleTranslations = <int, Offset>{};

  ValueListenable<Offset> translationFor(int objectId) {
    return _translations.putIfAbsent(
      objectId,
      () => ValueNotifier<Offset>(Offset.zero),
    );
  }

  void start(int objectId, DenialWindowPlacementEvent event) {
    assert(event.change == DenialWindowPlacementChange.move);
    _settleTranslations.remove(objectId);
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
    final session = _sessions.remove(objectId);
    final translation = _translations[objectId]?.value ?? Offset.zero;
    if (session != null && translation != Offset.zero) {
      // Retain the paint offset after clearing the live render transform.
      // Every position widget following the window, its frame and anything
      // it holds, reads it as the origin of its settle tween, preserving
      // exact visual continuity across the release frame. It only describes
      // that frame: a later release, such as an overview drag, must not start
      // from where this native grab once ended.
      _settleTranslations[objectId] = translation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_settleTranslations[objectId] == translation) {
          _settleTranslations.remove(objectId);
        }
      });
    } else {
      _settleTranslations.remove(objectId);
    }
    _setTranslation(objectId, Offset.zero);
    return session?.latestEvent;
  }

  /// The release origin left by [finish] for this frame, if any. Each widget
  /// following the window reads the same one; it is dropped after the frame.
  Offset? settleTranslation(int objectId) => _settleTranslations[objectId];

  void clear() {
    _sessions.clear();
    _settleTranslations.clear();
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
    _settleTranslations.clear();
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
