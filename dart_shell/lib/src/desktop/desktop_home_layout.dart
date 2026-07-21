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
  static const double idealItemHeight = 260.0;
  static const double minimumRowScale = 0.72;
  static const double maxJustifiedStretch = 1.18;

  static Map<String, Rect> arrange({
    required Rect bounds,
    required List<DesktopHomeLayoutItem> items,
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
      final requiredHeight =
          _totalHeight(heights, rowGap: rowGap, rowCount: rows.length);
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

    final requiredHeight =
        _totalHeight(heights, rowGap: rowGap, rowCount: rows.length);
    if (requiredHeight > content.height && heights.isNotEmpty) {
      final availableForItems = math.max(
        1.0,
        content.height - rowGap * (rows.length - 1),
      );
      final scale = availableForItems /
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

  static List<List<DesktopHomeLayoutItem>> _packRows(
    List<DesktopHomeLayoutItem> items, {
    required double targetHeight,
    required double availableWidth,
  }) {
    final rows = <List<DesktopHomeLayoutItem>>[];
    var row = <DesktopHomeLayoutItem>[];
    for (final item in items) {
      final candidate = <DesktopHomeLayoutItem>[...row, item];
      final minimumHeight = targetHeight * minimumRowScale;
      final candidateWidth = _itemsWidthAtHeight(candidate, minimumHeight) +
          itemGap * math.max(0, candidate.length - 1);
      if (row.isNotEmpty && candidateWidth > availableWidth) {
        rows.add(row);
        row = <DesktopHomeLayoutItem>[item];
      } else {
        row.add(item);
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
    for (var iteration = 0; iteration < 60; iteration += 1) {
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

  static double _widthAtHeight(
    DesktopHomeLayoutItem item,
    double height,
  ) {
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
    return math.min(
      requestedInset,
      math.max(0.0, (height - 0.001) / 2.0),
    );
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
