import 'package:flutter/widgets.dart';

import 'home_interactions.dart';

enum HomeResizeEdge { left, top, right, bottom }

/// Resizes a home widget from handles on its frame.
///
/// The frame follows the finger freely; the widget beneath snaps to the
/// cell span nearest the frame whenever that span fits.
class HomeResizeController {
  HomeResizeController(this._host);

  final HomeGridHost _host;

  /// The anchor of the widget showing its resize frame.
  final target = ValueNotifier<int?>(null);

  /// The frame while a handle is held, in grid coordinates.
  final frame = ValueNotifier<Rect?>(null);

  HomeResizeEdge? _edge;
  Offset _start = Offset.zero;
  Rect _startRect = Rect.zero;
  int _startColumn = 0;
  int _startRow = 0;
  int _startColSpan = 1;
  int _startRowSpan = 1;

  bool get active => target.value != null;
  bool get handleHeld => _edge != null;

  void enter(int index) {
    endHandle();
    target.value = index;
  }

  void exit() {
    endHandle();
    target.value = null;
  }

  void beginHandle(HomeResizeEdge edge, Offset global) {
    final index = target.value;
    final grid = _host.grid;
    final geometry = _host.geometry;
    final item = index == null || grid == null ? null : grid.slots[index];
    if (index == null || geometry == null || item == null) return;
    final local = index % geometry.pageSize;
    _edge = edge;
    _start = global;
    _startRect = geometry.itemRect(index, item);
    _startColumn = local % geometry.columns;
    _startRow = local ~/ geometry.columns;
    _startColSpan = item.colSpan;
    _startRowSpan = item.rowSpan;
    frame.value = _startRect;
  }

  void moveHandle(Offset global) {
    final edge = _edge;
    final index = target.value;
    final grid = _host.grid;
    final geometry = _host.geometry;
    final item = index == null || grid == null ? null : grid.slots[index];
    if (edge == null || index == null || geometry == null || item == null) {
      return;
    }

    double span(int cells, double tile) =>
        cells * tile + (cells - 1) * geometry.gap;
    final delta = global - _start;
    final rect = _startRect;
    final lastColumn = _startColumn + _startColSpan - 1;
    final lastRow = _startRow + _startRowSpan - 1;

    // Each edge moves within the spans the widget allows and the page has.
    final next = switch (edge) {
      HomeResizeEdge.right => Rect.fromLTRB(
        rect.left,
        rect.top,
        (rect.right + delta.dx).clamp(
          rect.left + span(item.minColSpan, geometry.tileSize.width),
          rect.left +
              span(
                (geometry.columns - _startColumn).clamp(1, item.maxColSpan),
                geometry.tileSize.width,
              ),
        ),
        rect.bottom,
      ),
      HomeResizeEdge.left => Rect.fromLTRB(
        (rect.left + delta.dx).clamp(
          rect.right -
              span(
                (lastColumn + 1).clamp(1, item.maxColSpan),
                geometry.tileSize.width,
              ),
          rect.right - span(item.minColSpan, geometry.tileSize.width),
        ),
        rect.top,
        rect.right,
        rect.bottom,
      ),
      HomeResizeEdge.bottom => Rect.fromLTRB(
        rect.left,
        rect.top,
        rect.right,
        (rect.bottom + delta.dy).clamp(
          rect.top + span(item.minRowSpan, geometry.tileSize.height),
          rect.top +
              span(
                (geometry.rows - _startRow).clamp(1, item.maxRowSpan),
                geometry.tileSize.height,
              ),
        ),
      ),
      HomeResizeEdge.top => Rect.fromLTRB(
        rect.left,
        (rect.top + delta.dy).clamp(
          rect.bottom -
              span(
                (lastRow + 1).clamp(1, item.maxRowSpan),
                geometry.tileSize.height,
              ),
          rect.bottom - span(item.minRowSpan, geometry.tileSize.height),
        ),
        rect.right,
        rect.bottom,
      ),
    };
    frame.value = next;

    final colSpan = ((next.width + geometry.gap) / geometry.stepX)
        .round()
        .clamp(item.minColSpan, item.maxColSpan);
    final rowSpan = ((next.height + geometry.gap) / geometry.stepY)
        .round()
        .clamp(item.minRowSpan, item.maxRowSpan);
    final column = edge == HomeResizeEdge.left
        ? lastColumn - colSpan + 1
        : _startColumn;
    final row = edge == HomeResizeEdge.top ? lastRow - rowSpan + 1 : _startRow;
    final anchor =
        index - index % geometry.pageSize + row * geometry.columns + column;
    if (anchor == index && colSpan == item.colSpan && rowSpan == item.rowSpan) {
      return;
    }
    final controller = _host.gridController;
    if (!controller.canResizeSlot(
      index,
      anchor,
      colSpan,
      rowSpan,
      geometry.pageSize,
    )) {
      return;
    }
    controller.resizeSlot(index, anchor, colSpan, rowSpan, geometry.pageSize);
    target.value = anchor;
  }

  /// Lets go of the handle: the frame settles onto the widget's span.
  void endHandle() {
    _edge = null;
    frame.value = null;
  }

  void dispose() {
    target.dispose();
    frame.dispose();
  }
}
