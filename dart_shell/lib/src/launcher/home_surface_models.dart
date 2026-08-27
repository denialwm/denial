part of 'home_surface.dart';

class _HomeResizeSession {
  const _HomeResizeSession({
    required this.item,
    required this.index,
    required this.pageSize,
    required this.startGlobalPosition,
    required this.startColSpan,
    required this.startRowSpan,
  });

  final HomeGridItem item;
  final int index;
  final int pageSize;
  final Offset startGlobalPosition;
  final int startColSpan;
  final int startRowSpan;
}

class _HomeGridSpan {
  const _HomeGridSpan({required this.colSpan, required this.rowSpan});

  final int colSpan;
  final int rowSpan;
}
