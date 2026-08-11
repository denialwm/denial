import 'dart:ui';

import 'home_grid_item.dart';

class HomeDragSession {
  const HomeDragSession({
    required this.item,
    required this.fromIndex,
    required this.pageSize,
    required this.pointerGlobalPosition,
    required this.localAnchor,
    required this.feedbackSize,
    this.targetIndex,
  });

  final HomeGridItem item;
  final int fromIndex;
  final int pageSize;
  final Offset pointerGlobalPosition;
  final Offset localAnchor;
  final Size feedbackSize;
  final int? targetIndex;

  String get itemId => item.id;

  HomeDragSession copyWith({
    Offset? pointerGlobalPosition,
    int? targetIndex,
    bool replaceTargetIndex = false,
  }) {
    return HomeDragSession(
      item: item,
      fromIndex: fromIndex,
      pageSize: pageSize,
      pointerGlobalPosition:
          pointerGlobalPosition ?? this.pointerGlobalPosition,
      localAnchor: localAnchor,
      feedbackSize: feedbackSize,
      targetIndex: replaceTargetIndex
          ? targetIndex
          : targetIndex ?? this.targetIndex,
    );
  }
}
