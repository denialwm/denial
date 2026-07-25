import 'package:flutter/material.dart';

import '../controllers/home_grid_layout.dart';
import '../models/desktop_app.dart';
import '../models/home_grid_item.dart';
import 'home_tiles.dart';

class HomeAppPage extends StatelessWidget {
  const HomeAppPage({
    super.key,
    required this.slots,
    required this.startIndex,
    required this.pageSize,
    required this.columns,
    required this.gap,
    required this.tileWidth,
    required this.tileHeight,
    required this.draggingSourceIndex,
    required this.resizeModeIndex,
    required this.onLaunch,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDragUpdate,
    required this.onResizeModeStart,
    required this.onResizeModeMove,
    required this.onResizeModeEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  static const double childAspectRatio = 0.78;

  final List<HomeGridItem?> slots;
  final int startIndex;
  final int pageSize;
  final int columns;
  final double gap;
  final double tileWidth;
  final double tileHeight;
  final int? draggingSourceIndex;
  final int? resizeModeIndex;
  final ValueChanged<DesktopApp> onLaunch;
  final void Function(
    HomeGridItem item,
    int fromIndex,
    int pageSize,
    LongPressStartDetails details,
    Size feedbackSize,
  ) onDragStart;
  final void Function(Offset? finalGlobalPosition) onDragEnd;
  final ValueChanged<LongPressMoveUpdateDetails> onDragUpdate;
  final void Function(
    HomeGridItem item,
    int index,
    int pageSize,
    LongPressStartDetails details,
  ) onResizeModeStart;
  final void Function(
    HomeGridItem item,
    int index,
    int pageSize,
    LongPressMoveUpdateDetails details,
    Size feedbackSize,
  ) onResizeModeMove;
  final VoidCallback onResizeModeEnd;
  final void Function(
    HomeGridItem item,
    int index,
    int pageSize,
    DragStartDetails details,
  ) onResizeStart;
  final ValueChanged<DragUpdateDetails> onResizeUpdate;
  final VoidCallback onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final pageEnd = startIndex + pageSize;
    final anchors = <int>[];

    for (var index = startIndex;
        index < pageEnd && index < slots.length;
        index += 1) {
      final item = slots[index];
      if (item == null) {
        continue;
      }
      final cells = HomeGridLayout.cellsFor(index, item, columns: columns);
      if (cells.every((cell) => cell >= startIndex && cell < pageEnd)) {
        anchors.add(index);
      }
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final anchor in anchors)
          _PositionedGridItem(
            key: ValueKey('item:${slots[anchor]!.id}'),
            index: anchor,
            startIndex: startIndex,
            columns: columns,
            gap: gap,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            item: slots[anchor]!,
            pageSize: pageSize,
            hidden: anchor == draggingSourceIndex,
            resizeActive: anchor == resizeModeIndex,
            resizeModeEnabled: resizeModeIndex != null,
            onLaunch: onLaunch,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDragUpdate: onDragUpdate,
            onResizeModeStart: onResizeModeStart,
            onResizeModeMove: onResizeModeMove,
            onResizeModeEnd: onResizeModeEnd,
            onResizeStart: onResizeStart,
            onResizeUpdate: onResizeUpdate,
            onResizeEnd: onResizeEnd,
          ),
      ],
    );
  }
}

class _PositionedGridItem extends StatelessWidget {
  const _PositionedGridItem({
    super.key,
    required this.index,
    required this.startIndex,
    required this.columns,
    required this.gap,
    required this.tileWidth,
    required this.tileHeight,
    required this.item,
    required this.pageSize,
    required this.hidden,
    required this.resizeActive,
    required this.resizeModeEnabled,
    required this.onLaunch,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDragUpdate,
    required this.onResizeModeStart,
    required this.onResizeModeMove,
    required this.onResizeModeEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
  });

  final int index;
  final int startIndex;
  final int columns;
  final double gap;
  final double tileWidth;
  final double tileHeight;
  final HomeGridItem item;
  final int pageSize;
  final bool hidden;
  final bool resizeActive;
  final bool resizeModeEnabled;
  final ValueChanged<DesktopApp> onLaunch;
  final void Function(
    HomeGridItem item,
    int fromIndex,
    int pageSize,
    LongPressStartDetails details,
    Size feedbackSize,
  ) onDragStart;
  final void Function(Offset? finalGlobalPosition) onDragEnd;
  final ValueChanged<LongPressMoveUpdateDetails> onDragUpdate;
  final void Function(
    HomeGridItem item,
    int index,
    int pageSize,
    LongPressStartDetails details,
  ) onResizeModeStart;
  final void Function(
    HomeGridItem item,
    int index,
    int pageSize,
    LongPressMoveUpdateDetails details,
    Size feedbackSize,
  ) onResizeModeMove;
  final VoidCallback onResizeModeEnd;
  final void Function(
    HomeGridItem item,
    int index,
    int pageSize,
    DragStartDetails details,
  ) onResizeStart;
  final ValueChanged<DragUpdateDetails> onResizeUpdate;
  final VoidCallback onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final localIndex = index - startIndex;
    final row = localIndex ~/ columns;
    final column = localIndex % columns;
    final width = item.colSpan * tileWidth + (item.colSpan - 1) * gap;
    final height = item.rowSpan * tileHeight + (item.rowSpan - 1) * gap;
    final card = HomeGridItemCard(
      item: item,
      launchEnabled: !resizeModeEnabled,
      onLaunch: onLaunch,
    );
    final tile = RepaintBoundary(child: card);
    final child = item.resizable && resizeActive
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: tile),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ResizeFramePainter(),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4, bottom: 4),
                  child: _ResizeHandle(
                    onPanStart: (details) => onResizeStart(
                      item,
                      index,
                      pageSize,
                      details,
                    ),
                    onPanUpdate: onResizeUpdate,
                    onPanEnd: onResizeEnd,
                  ),
                ),
              ),
            ],
          )
        : tile;

    return Positioned(
      left: column * (tileWidth + gap),
      top: row * (tileHeight + gap),
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: item.resizable
            ? (details) => onResizeModeStart(
                  item,
                  index,
                  pageSize,
                  details,
                )
            : (details) => onDragStart(
                  item,
                  index,
                  pageSize,
                  details,
                  Size(width, height),
                ),
        onLongPressMoveUpdate: item.resizable
            ? (details) => onResizeModeMove(
                  item,
                  index,
                  pageSize,
                  details,
                  Size(width, height),
                )
            : onDragUpdate,
        onLongPressEnd: item.resizable
            ? (_) => onResizeModeEnd()
            : (details) => onDragEnd(details.globalPosition),
        onLongPressCancel:
            item.resizable ? onResizeModeEnd : () => onDragEnd(null),
        child: hidden ? const SizedBox.shrink() : child,
      ),
    );
  }
}

class _ResizeFramePainter extends CustomPainter {
  const _ResizeFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = const Color(0xeef7f7f8)
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    final outline = rect.deflate(3);
    canvas.drawRRect(outline, border);

    final corner = Paint()
      ..color = const Color(0xfff7f7f8)
      ..style = PaintingStyle.fill;
    for (final offset in [
      outline.outerRect.topLeft,
      outline.outerRect.topRight,
      outline.outerRect.bottomLeft,
      outline.outerRect.bottomRight,
    ]) {
      canvas.drawCircle(offset, 7, corner);
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeFramePainter oldDelegate) {
    return false;
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final ValueChanged<DragStartDetails> onPanStart;
  final ValueChanged<DragUpdateDetails> onPanUpdate;
  final VoidCallback onPanEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: (_) => onPanEnd(),
      onPanCancel: onPanEnd,
      onLongPressStart: (_) {},
      onLongPressEnd: (_) {},
      onLongPressCancel: () {},
      child: SizedBox.square(
        dimension: 64,
        child: Align(
          alignment: Alignment.bottomRight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xddf7f7f8),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x8a070910)),
            ),
            child: const SizedBox.square(
              dimension: 56,
              child: Icon(
                Icons.open_in_full_rounded,
                size: 23,
                color: Color(0xff070910),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
