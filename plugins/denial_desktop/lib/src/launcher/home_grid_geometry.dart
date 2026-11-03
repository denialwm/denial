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
  const HomeGridGeometry({
    required this.columns,
    required this.rows,
    required this.tileSize,
    required this.inset,
    this.orientation = HomeOrientation.portrait,
    this.gap = HomeGridLayout.gridGap,
  });

  /// The grid for a pager of [size]. Wide panels get more columns rather
  /// than larger cells; rows fill the height.
  factory HomeGridGeometry.forViewport(Size size, {required double inset}) {
    final width = size.width - inset * 2;
    final columns = HomeGridLayout.columnsForViewport(width);
    const gap = HomeGridLayout.gridGap;
    final tileWidth = (width - gap * (columns - 1)) / columns;
    // Cell content is fixed-size, so height must not follow width past its
    // cap (phone tiles never reach it and keep the tuned aspect). A short
    // panel shrinks cells until its rows fit, down to the icon and label.
    final fittingHeight =
        (size.height - gap * (HomeGridLayout.minRows - 1)) /
        HomeGridLayout.minRows;
    final tileHeight = math.max(
      HomeGridLayout.minTileHeight,
      math.min(
        math.min(
          tileWidth / HomeTileMetrics.cellAspectRatio,
          HomeGridLayout.maxTileHeight,
        ),
        fittingHeight,
      ),
    );
    return HomeGridGeometry(
      columns: columns,
      rows: HomeGridLayout.rowsForHeight(size.height, tileHeight),
      tileSize: Size(tileWidth, tileHeight),
      inset: inset,
      orientation: size.width > size.height
          ? HomeOrientation.landscape
          : HomeOrientation.portrait,
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

  int get pageSize => columns * rows;
  double get stepX => tileSize.width + gap;
  double get stepY => tileSize.height + gap;
  double get width =>
      inset * 2 + columns * tileSize.width + (columns - 1) * gap;
  double get height => rows * tileSize.height + (rows - 1) * gap;

  /// The bounds of [colSpan] x [rowSpan] cells anchored at [index], on
  /// whichever page holds it.
  Rect rectAt(int index, {int colSpan = 1, int rowSpan = 1}) {
    final local = index % pageSize;
    return Rect.fromLTWH(
      inset + (local % columns) * stepX,
      (local ~/ columns) * stepY,
      colSpan * tileSize.width + (colSpan - 1) * gap,
      rowSpan * tileSize.height + (rowSpan - 1) * gap,
    );
  }

  Rect itemRect(int index, HomeGridItem item) =>
      rectAt(index, colSpan: item.colSpan, rowSpan: item.rowSpan);

  /// The cell of [page] under [point], or null outside the grid.
  int? cellAt(Offset point, int page) {
    final column = ((point.dx - inset + gap / 2) / stepX).floor();
    final row = ((point.dy + gap / 2) / stepY).floor();
    if (column < 0 || column >= columns || row < 0 || row >= rows) {
      return null;
    }
    return page * pageSize + row * columns + column;
  }

  @override
  bool operator ==(Object other) =>
      other is HomeGridGeometry &&
      other.columns == columns &&
      other.rows == rows &&
      other.tileSize == tileSize &&
      other.inset == inset &&
      other.orientation == orientation &&
      other.gap == gap;

  @override
  int get hashCode =>
      Object.hash(columns, rows, tileSize, inset, orientation, gap);
}
