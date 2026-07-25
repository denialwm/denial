import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DesktopWindowSwitcherPhase { pending, expanded, quickExit, expandedExit }

@immutable
class DesktopWindowSwitcherState {
  const DesktopWindowSwitcherState({
    required this.sessionId,
    required this.objectIds,
    required this.sourceObjectId,
    required this.usesDesktopMotion,
    required this.selectedIndex,
    required this.phase,
  });

  final int sessionId;
  final List<int> objectIds;

  /// The non-minimized window the switch begins from.
  ///
  /// This is null when every candidate is already a desktop widget. In that
  /// case the first candidate is selected directly instead of promoting a
  /// minimized window into a fake foreground source first.
  final int? sourceObjectId;

  /// Whether at least one candidate entered from the desktop widget plane.
  ///
  /// These sessions use the complete switcher arrangement from their first
  /// frame and return minimized candidates to desktop coordinates on exit.
  /// They must never pass through the legacy two-window quick transition.
  final bool usesDesktopMotion;
  final int selectedIndex;
  final DesktopWindowSwitcherPhase phase;

  int get selectedObjectId => objectIds[selectedIndex];

  bool get isSelecting =>
      phase == DesktopWindowSwitcherPhase.pending ||
      phase == DesktopWindowSwitcherPhase.expanded;

  bool get isExpanded => phase == DesktopWindowSwitcherPhase.expanded;

  bool get usesExpandedTransition => usesDesktopMotion || isExpanded;

  bool get expandedChromeVisible => isSelecting && isExpanded;

  DesktopWindowSwitcherState copyWith({
    List<int>? objectIds,
    int? sourceObjectId,
    bool clearSourceObjectId = false,
    bool? usesDesktopMotion,
    int? selectedIndex,
    DesktopWindowSwitcherPhase? phase,
  }) {
    return DesktopWindowSwitcherState(
      sessionId: sessionId,
      objectIds: objectIds ?? this.objectIds,
      sourceObjectId: clearSourceObjectId
          ? null
          : sourceObjectId ?? this.sourceObjectId,
      usesDesktopMotion: usesDesktopMotion ?? this.usesDesktopMotion,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      phase: phase ?? this.phase,
    );
  }
}

final desktopWindowSwitcherProvider =
    NotifierProvider<
      DesktopWindowSwitcherController,
      DesktopWindowSwitcherState?
    >(DesktopWindowSwitcherController.new);

class DesktopWindowSwitcherController
    extends Notifier<DesktopWindowSwitcherState?> {
  @override
  DesktopWindowSwitcherState? build() => null;

  int _nextSessionId = 1;

  DesktopWindowSwitcherState? beginOrAdvance({
    required List<int> objectIds,
    required int? sourceObjectId,
    required bool usesDesktopMotion,
  }) {
    final uniqueIds = <int>[];
    final seen = <int>{};
    for (final objectId in objectIds) {
      if (seen.add(objectId)) {
        uniqueIds.add(objectId);
      }
    }
    if (uniqueIds.isEmpty ||
        (sourceObjectId != null &&
            (uniqueIds.length < 2 || !seen.contains(sourceObjectId)))) {
      return null;
    }

    final current = state;
    if (current != null && current.isSelecting) {
      final selectedId = current.selectedObjectId;
      final reconciled = current.objectIds
          .where(seen.contains)
          .toList(growable: false);
      final currentSource = current.sourceObjectId;
      final reconciledSource =
          currentSource != null && seen.contains(currentSource)
          ? currentSource
          : sourceObjectId;
      if (reconciled.isEmpty ||
          (reconciledSource != null && reconciled.length < 2)) {
        state = null;
        return null;
      }
      final selectedIndex = reconciled.indexOf(selectedId);
      final nextIndex =
          ((selectedIndex < 0 ? 0 : selectedIndex) + 1) % reconciled.length;
      state = current.copyWith(
        objectIds: List<int>.unmodifiable(reconciled),
        sourceObjectId: reconciledSource,
        clearSourceObjectId: reconciledSource == null,
        usesDesktopMotion: current.usesDesktopMotion || usesDesktopMotion,
        selectedIndex: nextIndex,
      );
      return state;
    }

    if (sourceObjectId != null) {
      uniqueIds
        ..remove(sourceObjectId)
        ..insert(0, sourceObjectId);
    }
    state = DesktopWindowSwitcherState(
      sessionId: _nextSessionId++,
      objectIds: List<int>.unmodifiable(uniqueIds),
      sourceObjectId: sourceObjectId,
      usesDesktopMotion: usesDesktopMotion,
      selectedIndex: sourceObjectId == null ? 0 : 1,
      phase: DesktopWindowSwitcherPhase.pending,
    );
    return state;
  }

  void expand(int sessionId) {
    final current = state;
    if (current == null ||
        current.sessionId != sessionId ||
        current.phase != DesktopWindowSwitcherPhase.pending) {
      return;
    }
    state = current.copyWith(phase: DesktopWindowSwitcherPhase.expanded);
  }

  void beginQuickExit(int sessionId) {
    final current = state;
    if (current == null || current.sessionId != sessionId) {
      return;
    }
    state = current.copyWith(phase: DesktopWindowSwitcherPhase.quickExit);
  }

  void beginExpandedExit(int sessionId) {
    final current = state;
    if (current == null || current.sessionId != sessionId) {
      return;
    }
    state = current.copyWith(phase: DesktopWindowSwitcherPhase.expandedExit);
  }

  void clear(int sessionId) {
    if (state?.sessionId == sessionId) {
      state = null;
    }
  }

  void cancel() {
    state = null;
  }
}
