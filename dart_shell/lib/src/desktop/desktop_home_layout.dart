import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// One non-overlapping item on the persistent desktop plane.
@immutable
class DesktopHomeLayoutItem {
  const DesktopHomeLayoutItem({
    required this.id,
    this.preferredAspectRatio = 2.0,
    this.contentAspectRatio,
    this.frameInset = 0.0,
  });

  final String id;

  /// Outer aspect ratio used by ordinary Flutter widgets.
  final double preferredAspectRatio;

  /// Aspect ratio of the content inside [frameInset]. When present, both the
  /// packed rectangle and every animated intermediate frame preserve it.
  final double? contentAspectRatio;
  final double frameInset;
}

/// Packs variable-aspect desktop items into compact rows.
///
/// This is intentionally not a cell grid. Each item keeps its natural shape;
/// rows wrap and gently justify like a gallery, leaving no visible empty cells
/// and never allowing neighboring items to overlap.
class DesktopHomeLayout {
  const DesktopHomeLayout._();

  static const double outerPadding = 32.0;
  static const double itemGap = 14.0;
  static const double denseItemGap = 6.0;
  static const double idealItemHeight = 260.0;
  static const double minimumRowScale = 0.72;
  static const double maxJustifiedStretch = 1.18;
  static const int denseWindowThreshold = 64;

  static bool usesDenseWindowMode(int minimizedWindowCount) {
    return minimizedWindowCount >= denseWindowThreshold;
  }

  /// Returns a minimize destination directly below the canvas while
  /// preserving the window's retained horizontal position and layout size.
  static Rect offscreenFrame({required Rect bounds, required Rect source}) {
    if (bounds.isEmpty || source.isEmpty) {
      return source;
    }
    return Rect.fromLTWH(
      source.left,
      bounds.bottom + outerPadding,
      source.width,
      source.height,
    );
  }

  static Map<String, Rect> arrange({
    required Rect bounds,
    required List<DesktopHomeLayoutItem> items,
    bool dense = false,
  }) {
    if (bounds.isEmpty || items.isEmpty) {
      return const <String, Rect>{};
    }

    final padding = math.min(
      outerPadding,
      math.min(bounds.width, bounds.height) / 8.0,
    );
    final content = bounds.deflate(math.max(0.0, padding));
    if (content.isEmpty) {
      return const <String, Rect>{};
    }

    final uniqueItems = <DesktopHomeLayoutItem>[];
    final seenIds = <String>{};
    for (final item in items) {
      if (seenIds.add(item.id)) {
        uniqueItems.add(item);
      }
    }
    if (dense) {
      return _arrangeDense(bounds: content, items: uniqueItems);
    }

    var targetHeight = math.min(
      idealItemHeight,
      math.max(1.0, content.height * 0.28),
    );
    var rows = _packRows(
      uniqueItems,
      targetHeight: targetHeight,
      availableWidth: content.width,
    );
    var rowGap = _rowGap(content.height, rows.length);
    var heights = _rowHeights(
      rows,
      targetHeight: targetHeight,
      availableWidth: content.width,
    );

    // Repack at a smaller natural height when the first pass would run below
    // the output. Smaller items allow more windows per row instead of merely
    // crushing the original row membership vertically.
    for (var attempt = 0; attempt < 8; attempt += 1) {
      final requiredHeight = _totalHeight(
        heights,
        rowGap: rowGap,
        rowCount: rows.length,
      );
      if (requiredHeight <= content.height + 0.001) {
        break;
      }
      final shrink = (content.height / requiredHeight).clamp(0.35, 0.9);
      targetHeight = math.max(1.0, targetHeight * shrink);
      rows = _packRows(
        uniqueItems,
        targetHeight: targetHeight,
        availableWidth: content.width,
      );
      rowGap = _rowGap(content.height, rows.length);
      heights = _rowHeights(
        rows,
        targetHeight: targetHeight,
        availableWidth: content.width,
      );
    }

    final requiredHeight = _totalHeight(
      heights,
      rowGap: rowGap,
      rowCount: rows.length,
    );
    if (requiredHeight > content.height && heights.isNotEmpty) {
      final availableForItems = math.max(
        1.0,
        content.height - rowGap * (rows.length - 1),
      );
      final scale =
          availableForItems /
          heights.fold<double>(0.0, (total, height) => total + height);
      heights = <double>[for (final height in heights) height * scale];
    }

    final frames = <String, Rect>{};
    var top = content.top;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      final row = rows[rowIndex];
      final height = heights[rowIndex];
      var left = content.left;
      for (final item in row) {
        final width = _widthAtHeight(item, height);
        frames[item.id] = Rect.fromLTWH(left, top, width, height);
        left += width + itemGap;
      }
      top += height + rowGap;
    }
    return frames;
  }

  static Map<String, Rect> _arrangeDense({
    required Rect bounds,
    required List<DesktopHomeLayoutItem> items,
  }) {
    final averageAspect =
        items.fold<double>(
          0.0,
          (sum, item) => sum + _widthAtHeight(item, 100.0) / 100.0,
        ) /
        items.length;
    ({
      int columns,
      int rows,
      double cellWidth,
      double cellHeight,
      double score,
    })?
    best;

    for (var columns = 1; columns <= items.length; columns += 1) {
      final rows = (items.length + columns - 1) ~/ columns;
      final widthForCells = bounds.width - denseItemGap * (columns - 1);
      final heightForCells = bounds.height - denseItemGap * (rows - 1);
      if (widthForCells <= 0.0 || heightForCells <= 0.0) {
        continue;
      }
      final cellWidth = widthForCells / columns;
      final cellHeight = heightForCells / rows;
      final previewHeight = math.min(cellHeight, cellWidth / averageAspect);
      final previewWidth = previewHeight * averageAspect;
      final utilization = items.length / (columns * rows);
      final score = previewWidth * previewHeight * (0.92 + 0.08 * utilization);
      if (best == null || score > best.score) {
        best = (
          columns: columns,
          rows: rows,
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          score: score,
        );
      }
    }
    if (best == null) {
      return const <String, Rect>{};
    }

    final frames = <String, Rect>{};
    for (var index = 0; index < items.length; index += 1) {
      final row = index ~/ best.columns;
      final column = index % best.columns;
      final rowStart = row * best.columns;
      final rowItemCount = math.min(best.columns, items.length - rowStart);
      final rowWidth =
          best.cellWidth * rowItemCount +
          denseItemGap * math.max(0, rowItemCount - 1);
      final cell = Rect.fromLTWH(
        bounds.left +
            (bounds.width - rowWidth) / 2.0 +
            column * (best.cellWidth + denseItemGap),
        bounds.top + row * (best.cellHeight + denseItemGap),
        best.cellWidth,
        best.cellHeight,
      );
      final item = items[index];
      final height = _heightInsideCell(item, cell.size);
      frames[item.id] = Rect.fromCenter(
        center: cell.center,
        width: _widthAtHeight(item, height),
        height: height,
      );
    }
    return frames;
  }

  static double _heightInsideCell(DesktopHomeLayoutItem item, Size cell) {
    if (_widthAtHeight(item, cell.height) <= cell.width) {
      return cell.height;
    }
    var low = 0.001;
    var high = cell.height;
    for (var iteration = 0; iteration < 32; iteration += 1) {
      final middle = (low + high) / 2.0;
      if (_widthAtHeight(item, middle) > cell.width) {
        high = middle;
      } else {
        low = middle;
      }
    }
    return math.max(0.001, low);
  }

  static List<List<DesktopHomeLayoutItem>> _packRows(
    List<DesktopHomeLayoutItem> items, {
    required double targetHeight,
    required double availableWidth,
  }) {
    final rows = <List<DesktopHomeLayoutItem>>[];
    var row = <DesktopHomeLayoutItem>[];
    var rowWidth = 0.0;
    final minimumHeight = targetHeight * minimumRowScale;
    for (final item in items) {
      final itemWidth = _widthAtHeight(item, minimumHeight);
      final candidateWidth =
          rowWidth + (row.isEmpty ? 0.0 : itemGap) + itemWidth;
      if (row.isNotEmpty && candidateWidth > availableWidth) {
        rows.add(row);
        row = <DesktopHomeLayoutItem>[item];
        rowWidth = itemWidth;
      } else {
        row.add(item);
        rowWidth = candidateWidth;
      }
    }
    if (row.isNotEmpty) {
      rows.add(row);
    }

    // Greedy packing can strand one narrow item on the final row. Rebalance
    // the last two rows while preserving order so the desktop reads as a
    // composed canvas rather than a list with an orphan thumbnail.
    if (rows.length >= 2) {
      final previous = rows[rows.length - 2];
      final last = rows.last;
      while (last.length + 1 < previous.length && previous.length > 2) {
        last.insert(0, previous.removeLast());
      }
    }
    return <List<DesktopHomeLayoutItem>>[
      for (final packedRow in rows)
        List<DesktopHomeLayoutItem>.unmodifiable(packedRow),
    ];
  }

  static List<double> _rowHeights(
    List<List<DesktopHomeLayoutItem>> rows, {
    required double targetHeight,
    required double availableWidth,
  }) {
    return <double>[
      for (var index = 0; index < rows.length; index += 1)
        math.min(
          _heightForWidth(rows[index], availableWidth),
          index == rows.length - 1
              ? targetHeight
              : targetHeight * maxJustifiedStretch,
        ),
    ];
  }

  static double _heightForWidth(
    List<DesktopHomeLayoutItem> row,
    double availableWidth,
  ) {
    final widthForItems = math.max(
      0.001,
      availableWidth - itemGap * math.max(0, row.length - 1),
    );
    var low = 0.001;
    var high = idealItemHeight;
    while (_itemsWidthAtHeight(row, high) < widthForItems && high < 65536.0) {
      high *= 2.0;
    }
    // 32 bisections retain substantially better than sub-pixel precision for
    // the supported desktop sizes; the former 60 iterations only refined
    // floating-point noise while multiplying work across repack attempts.
    for (var iteration = 0; iteration < 32; iteration += 1) {
      final middle = (low + high) / 2.0;
      if (_itemsWidthAtHeight(row, middle) > widthForItems) {
        high = middle;
      } else {
        low = middle;
      }
    }
    return math.max(0.001, low);
  }

  static double _itemsWidthAtHeight(
    List<DesktopHomeLayoutItem> row,
    double height,
  ) {
    return row.fold<double>(
      0.0,
      (width, item) => width + _widthAtHeight(item, height),
    );
  }

  static double _widthAtHeight(DesktopHomeLayoutItem item, double height) {
    final contentRatio = item.contentAspectRatio;
    if (contentRatio != null && contentRatio.isFinite && contentRatio > 0.0) {
      final inset = _safeInset(item.frameInset, height);
      return math.max(0.001, height - inset * 2.0) * contentRatio + inset * 2.0;
    }
    final preferredRatio =
        item.preferredAspectRatio.isFinite && item.preferredAspectRatio > 0.0
        ? item.preferredAspectRatio
        : 2.0;
    return height * preferredRatio;
  }

  static double _safeInset(double requestedInset, double height) {
    if (!requestedInset.isFinite || requestedInset <= 0.0) {
      return 0.0;
    }
    return math.min(requestedInset, math.max(0.0, (height - 0.001) / 2.0));
  }

  static double _rowGap(double height, int rowCount) {
    if (rowCount <= 1) {
      return 0.0;
    }
    return math.min(itemGap, height / (rowCount * 3.0));
  }

  static double _totalHeight(
    List<double> heights, {
    required double rowGap,
    required int rowCount,
  }) {
    return heights.fold<double>(0.0, (total, height) => total + height) +
        rowGap * math.max(0, rowCount - 1);
  }
}
