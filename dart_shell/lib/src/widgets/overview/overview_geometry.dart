import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../input/input_layout.dart';
import '../window_geometry.dart';

const double _overviewLabelExtent = 44.0;
const double _singlePreviewWidthFraction = 0.66;
const double _singlePreviewMaxWidth = 840.0;

/// The equal-sized slots used by the landscape recents overview.
///
/// [itemRects] include the title below each preview, while [previewRectAt]
/// returns the exact live-texture rect used by the foreground hero.
class LandscapeOverviewLayout {
  const LandscapeOverviewLayout({
    required this.cardSize,
    required this.itemRects,
    required this.columns,
    required this.rows,
  });

  final Size cardSize;
  final List<Rect> itemRects;
  final int columns;
  final int rows;

  Rect previewRectAt(int index) {
    final itemRect = itemRects[index];
    return Rect.fromLTWH(
      itemRect.left,
      itemRect.top,
      cardSize.width,
      cardSize.height,
    );
  }
}

double viewAspectFor(Size size) {
  if (size.width <= 0.0 || size.height <= 0.0) {
    return kPreviewAspect;
  }
  return (size.width / size.height)
      .clamp(kMinPreviewAspect, kMaxPreviewAspect)
      .toDouble();
}

/// Computes the preview card size that fits the carousel within [constraints].
Size cardSizeFor({
  required BoxConstraints constraints,
  required EdgeInsets padding,
  required double aspect,
}) {
  final availableWidth = math.max(
    0.0,
    constraints.maxWidth - padding.horizontal,
  );
  final availableHeight = math.max(
    260.0,
    constraints.maxHeight - padding.vertical - 210.0,
  );
  final maxWidth = math.min(availableWidth * 0.74, 410.0);
  final maxHeight = math.min(availableHeight, constraints.maxHeight * 0.66);

  var width = maxWidth;
  var height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }

  return Size(width, height);
}

/// The centred rect a preview card occupies when the overview is fully open.
Rect centerPreviewRectFor(Size viewSize, Size cardSize) {
  final left = (viewSize.width - cardSize.width) / 2.0;
  final top = (viewSize.height - cardSize.height) / 2.0 - 22.0;
  return Rect.fromLTWH(left, top, cardSize.width, cardSize.height);
}

/// Packs every recent app into the largest possible equal-sized landscape
/// grid. The search considers every column count, so two apps can spread into
/// one row while larger sets naturally become balanced rows. Incomplete final
/// rows are centred instead of being pinned to the leading edge.
LandscapeOverviewLayout landscapeOverviewLayoutFor({
  required Size viewSize,
  required EdgeInsets padding,
  required int itemCount,
  required double aspect,
}) {
  assert(itemCount > 0);

  final horizontalMargin = (viewSize.width * 0.035)
      .clamp(28.0, 56.0)
      .toDouble();
  final topMargin =
      ShellMetrics.statusBarHeight +
      (viewSize.height * 0.02).clamp(12.0, 20.0).toDouble();
  final bottomMargin =
      ShellMetrics.gestureHitHeight + ShellMetrics.gestureBottomInset + 8.0;
  final horizontalGap = (viewSize.width * 0.018).clamp(16.0, 28.0).toDouble();
  final verticalGap = (viewSize.height * 0.03).clamp(14.0, 22.0).toDouble();

  final contentRect = Rect.fromLTRB(
    padding.left + horizontalMargin,
    padding.top + topMargin,
    math.max(
      padding.left + horizontalMargin + 1.0,
      viewSize.width - padding.right - horizontalMargin,
    ),
    math.max(
      padding.top + topMargin + 1.0,
      viewSize.height - padding.bottom - bottomMargin,
    ),
  );
  final safeAspect = aspect <= 0.0 ? kPreviewAspect : aspect;

  var bestColumns = 1;
  var bestRows = itemCount;
  var bestCardSize = Size.zero;
  var bestArea = -1.0;
  var bestEmptySlots = itemCount;

  for (var columns = 1; columns <= itemCount; columns += 1) {
    final rows = (itemCount / columns).ceil();
    final cellWidth =
        (contentRect.width - horizontalGap * (columns - 1)) / columns;
    final itemHeight = (contentRect.height - verticalGap * (rows - 1)) / rows;
    final maxPreviewHeight = itemHeight - _overviewLabelExtent;
    if (cellWidth <= 0.0 || maxPreviewHeight <= 0.0) {
      continue;
    }

    final width = math.min(cellWidth, maxPreviewHeight * safeAspect);
    final height = width / safeAspect;
    final area = width * height;
    final emptySlots = rows * columns - itemCount;
    final isLarger = area > bestArea + 0.01;
    final isTighterAtSameSize =
        (area - bestArea).abs() <= 0.01 && emptySlots < bestEmptySlots;
    if (!isLarger && !isTighterAtSameSize) {
      continue;
    }

    bestColumns = columns;
    bestRows = rows;
    bestCardSize = Size(width, height);
    bestArea = area;
    bestEmptySlots = emptySlots;
  }

  if (bestCardSize == Size.zero) {
    final width = math.max(1.0, contentRect.width / itemCount);
    bestColumns = itemCount;
    bestRows = 1;
    bestCardSize = Size(width, math.max(1.0, width / safeAspect));
  }

  if (itemCount == 1) {
    final maxSingleWidth = math.max(
      1.0,
      math.min(
        contentRect.width * _singlePreviewWidthFraction,
        _singlePreviewMaxWidth,
      ),
    );
    final width = math.min(bestCardSize.width, maxSingleWidth);
    bestCardSize = Size(width, width / safeAspect);
  }

  final itemHeight = bestCardSize.height + _overviewLabelExtent;
  final gridHeight = itemHeight * bestRows + verticalGap * (bestRows - 1);
  final gridTop = contentRect.top + (contentRect.height - gridHeight) / 2.0;
  final itemRects = <Rect>[];

  for (var row = 0; row < bestRows; row += 1) {
    final firstIndex = row * bestColumns;
    final itemsInRow = math.min(bestColumns, itemCount - firstIndex);
    final rowWidth =
        bestCardSize.width * itemsInRow + horizontalGap * (itemsInRow - 1);
    final rowLeft = contentRect.left + (contentRect.width - rowWidth) / 2.0;
    final top = gridTop + row * (itemHeight + verticalGap);

    for (var column = 0; column < itemsInRow; column += 1) {
      itemRects.add(
        Rect.fromLTWH(
          rowLeft + column * (bestCardSize.width + horizontalGap),
          top,
          bestCardSize.width,
          itemHeight,
        ),
      );
    }
  }

  return LandscapeOverviewLayout(
    cardSize: bestCardSize,
    itemRects: List<Rect>.unmodifiable(itemRects),
    columns: bestColumns,
    rows: bestRows,
  );
}
