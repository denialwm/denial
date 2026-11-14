import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/applications.dart';

/// Fixed sizes of an app or folder tile: its icon above its label.
abstract final class HomeTileMetrics {
  static const double iconBox = 92;
  static const double icon = 85;
  static const double labelGap = 9;

  /// Width over height of a cell on a phone.
  static const double cellAspectRatio = 0.78;

  /// Corner radius of a folder plate, and of the window that grows from or
  /// shrinks into an icon, relative to the icon's size.
  static const double iconRadiusFraction = 0.24;

  /// Where a tile anchored in [cell] draws its icon.
  static Rect iconRectIn(Rect cell) => Rect.fromCenter(
    center: Offset(cell.center.dx, cell.top + iconBox / 2),
    width: icon,
    height: icon,
  );
}

/// Where the home grid's cells are for one layout of the pager.
///
/// Every page shares these coordinates: the grid viewport's own, with the
/// current page settled in it.
@immutable
class HomeGridGeometry {
  HomeGridGeometry({
    required this.columns,
    required this.rows,
    required this.tileSize,
    required this.inset,
    this.orientation = HomeOrientation.portrait,
    this.gap = HomeGridLayout.gridGap,
    double? bottomRowTop,
    this.sharedBottomRow = false,
  }) : bottomRowTop = bottomRowTop ?? (rows - 1) * (tileSize.height + gap);

  /// The grid for a pager of [size]. Wide panels get more columns and rows
  /// rather than larger cells; rows fill the height but [rowGap] above the
  /// bottom row, which sits at the bottom of [size] with any height left
  /// over above it.
  factory HomeGridGeometry.forViewport(
    Size size, {
    required double inset,
    double rowGap = 0,
    bool sharedBottomRow = false,
  }) {
    final width = size.width - inset * 2;
    final columns = HomeGridLayout.columnsForViewport(width);
    const gap = HomeGridLayout.gridGap;
    final tileWidth = (width - gap * (columns - 1)) / columns;
    // Cell content is fixed-size. Phone cells keep the tuned aspect, and a
    // short panel shrinks them until its rows fit, down to the icon and
    // label; cells that aspect would make taller than the cap are a
    // tablet's, which takes rows of icon and label instead.
    final rowsHeight = size.height - rowGap;
    final phoneHeight = tileWidth / HomeTileMetrics.cellAspectRatio;
    final double tileHeight;
    final int rows;
    if (phoneHeight > HomeGridLayout.maxTileHeight) {
      // As many rows as the height takes, sharing what is left over.
      rows = HomeGridLayout.rowsForHeight(
        rowsHeight,
        HomeGridLayout.minTileHeight,
      );
      tileHeight = math.max(
        HomeGridLayout.minTileHeight,
        (rowsHeight - gap * (rows - 1)) / rows,
      );
    } else {
      final fittingHeight =
          (rowsHeight - gap * (HomeGridLayout.minRows - 1)) /
          HomeGridLayout.minRows;
      tileHeight = math.max(
        HomeGridLayout.minTileHeight,
        math.min(phoneHeight, fittingHeight),
      );
      rows = HomeGridLayout.rowsForHeight(rowsHeight, tileHeight);
    }
    return HomeGridGeometry(
      columns: columns,
      rows: rows,
      tileSize: Size(tileWidth, tileHeight),
      inset: inset,
      orientation: size.width > size.height
          ? HomeOrientation.landscape
          : HomeOrientation.portrait,
      bottomRowTop: rows < 2
          ? 0
          : math.max(
              (rows - 1) * (tileHeight + gap) + rowGap,
              size.height - tileHeight,
            ),
      sharedBottomRow: sharedBottomRow && rows >= 2,
    );
  }

  final int columns;
  final int rows;
  final Size tileSize;

  /// Horizontal margin between the viewport and the first column.
  final double inset;

  /// Which of its layouts the grid shows.
  final HomeOrientation orientation;
  final double gap;

  /// Where the bottom row starts: at the bottom of the viewport, apart from
  /// the rows above it ([HomeGridLayout.inBottomRow]).
  final double bottomRowTop;

  /// The first page's bottom row shows on every page.
  final bool sharedBottomRow;

  int get pageSize => columns * rows;
  double get stepX => tileSize.width + gap;
  double get stepY => tileSize.height + gap;
  double get width =>
      inset * 2 + columns * tileSize.width + (columns - 1) * gap;
  double get height => bottomRowTop + tileSize.height;

  /// The height a page's own items take: a shared bottom row is no page's.
  double get pageHeight => sharedBottomRow ? upperRows * stepY - gap : height;

  /// The rows above the bottom row, where taller widgets fit.
  int get upperRows => rows < 2 ? rows : rows - 1;

  double _rowTop(int row) => row == rows - 1 ? bottomRowTop : row * stepY;

  /// The bounds of [colSpan] x [rowSpan] cells anchored at [index], on
  /// whichever page holds it.
  Rect rectAt(int index, {int colSpan = 1, int rowSpan = 1}) {
    final local = index % pageSize;
    return Rect.fromLTWH(
      inset + (local % columns) * stepX,
      _rowTop(local ~/ columns),
      colSpan * tileSize.width + (colSpan - 1) * gap,
      rowSpan * tileSize.height + (rowSpan - 1) * gap,
    );
  }

  /// The cell at [row] and [column] as [page] shows it: a shared bottom row
  /// is the first page's.
  int indexAt(int page, int row, int column) =>
      (sharedBottomRow && row == rows - 1 ? 0 : page) * pageSize +
      row * columns +
      column;

  bool inBottomRow(int index) =>
      rows >= 2 && (index % pageSize) ~/ columns == rows - 1;

  /// Whether [page] shows the item anchored at [index].
  bool shows(int index, int page) =>
      index ~/ pageSize == page ||
      (sharedBottomRow && index < pageSize && inBottomRow(index));

  Rect itemRect(int index, HomeGridItem item) =>
      rectAt(index, colSpan: item.colSpan, rowSpan: item.rowSpan);

  /// The cell of [page] under [point], or null outside the grid.
  int? cellAt(Offset point, int page) {
    final column = ((point.dx - inset + gap / 2) / stepX).floor();
    final bottom = rows >= 2 && point.dy >= bottomRowTop - gap / 2;
    final row = bottom
        ? (point.dy < bottomRowTop + tileSize.height + gap / 2 ? rows - 1 : -1)
        : ((point.dy + gap / 2) / stepY).floor();
    if (column < 0 ||
        column >= columns ||
        row < 0 ||
        row >= (bottom ? rows : upperRows)) {
      return null;
    }
    return indexAt(page, row, column);
  }

  @override
  bool operator ==(Object other) =>
      other is HomeGridGeometry &&
      other.columns == columns &&
      other.rows == rows &&
      other.tileSize == tileSize &&
      other.inset == inset &&
      other.orientation == orientation &&
      other.gap == gap &&
      other.bottomRowTop == bottomRowTop &&
      other.sharedBottomRow == sharedBottomRow;

  @override
  int get hashCode => Object.hash(
    columns,
    rows,
    tileSize,
    inset,
    orientation,
    gap,
    bottomRowTop,
    sharedBottomRow,
  );
}
