import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DesktopWindowSwitcherPhase {
  pending,
  expanded,
  quickExit,
  expandedExit,
}

@immutable
class DesktopWindowSwitcherState {
  const DesktopWindowSwitcherState({
    required this.sessionId,
    required this.objectIds,
    required this.sourceObjectId,
    required this.selectedIndex,
    required this.phase,
  });

  final int sessionId;
  final List<int> objectIds;
  final int sourceObjectId;
  final int selectedIndex;
  final DesktopWindowSwitcherPhase phase;

  int get selectedObjectId => objectIds[selectedIndex];

  bool get isSelecting =>
      phase == DesktopWindowSwitcherPhase.pending ||
      phase == DesktopWindowSwitcherPhase.expanded;

  bool get isExpanded => phase == DesktopWindowSwitcherPhase.expanded;

  DesktopWindowSwitcherState copyWith({
    List<int>? objectIds,
    int? sourceObjectId,
    int? selectedIndex,
    DesktopWindowSwitcherPhase? phase,
  }) {
    return DesktopWindowSwitcherState(
      sessionId: sessionId,
      objectIds: objectIds ?? this.objectIds,
      sourceObjectId: sourceObjectId ?? this.sourceObjectId,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      phase: phase ?? this.phase,
    );
  }
}

final desktopWindowSwitcherProvider = StateNotifierProvider<
    DesktopWindowSwitcherController, DesktopWindowSwitcherState?>((ref) {
  return DesktopWindowSwitcherController();
});

class DesktopWindowSwitcherController
    extends StateNotifier<DesktopWindowSwitcherState?> {
  DesktopWindowSwitcherController() : super(null);

  int _nextSessionId = 1;

  DesktopWindowSwitcherState? beginOrAdvance({
    required List<int> objectIds,
    required int sourceObjectId,
  }) {
    final uniqueIds = <int>[];
    final seen = <int>{};
    for (final objectId in objectIds) {
      if (seen.add(objectId)) {
        uniqueIds.add(objectId);
      }
    }
    if (uniqueIds.length < 2 || !seen.contains(sourceObjectId)) {
      return null;
    }

    final current = state;
    if (current != null && current.isSelecting) {
      final selectedId = current.selectedObjectId;
      final reconciled =
          current.objectIds.where(seen.contains).toList(growable: false);
      if (reconciled.length < 2) {
        state = null;
        return null;
      }
      final selectedIndex = reconciled.indexOf(selectedId);
      final nextIndex =
          ((selectedIndex < 0 ? 0 : selectedIndex) + 1) % reconciled.length;
      state = current.copyWith(
        objectIds: List<int>.unmodifiable(reconciled),
        sourceObjectId: seen.contains(current.sourceObjectId)
            ? current.sourceObjectId
            : sourceObjectId,
        selectedIndex: nextIndex,
      );
      return state;
    }

    uniqueIds
      ..remove(sourceObjectId)
      ..insert(0, sourceObjectId);
    state = DesktopWindowSwitcherState(
      sessionId: _nextSessionId++,
      objectIds: List<int>.unmodifiable(uniqueIds),
      sourceObjectId: sourceObjectId,
      selectedIndex: 1,
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
