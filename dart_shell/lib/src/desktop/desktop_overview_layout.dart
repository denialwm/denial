import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The stable geometry needed to place one live window in desktop overview.
class DesktopOverviewItem {
  const DesktopOverviewItem({
    required this.objectId,
    required this.frame,
    required this.z,
  });

  final int objectId;
  final Rect frame;
  final int z;

  double get aspectRatio {
    if (frame.width <= 0.0 || frame.height <= 0.0) {
      return 16.0 / 10.0;
    }
    return (frame.width / frame.height).clamp(0.32, 3.6).toDouble();
  }
}

/// Packs windows into justified rows while preserving every aspect ratio.
///
/// Candidates with different row counts are compared by occupied area. Within
/// a candidate, windows keep their approximate top-to-bottom, left-to-right
/// order so opening overview does not visually shuffle the desktop.
abstract final class DesktopOverviewLayout {
  static const double gap = 18.0;
  static const double outerPadding = 30.0;
  static const double minimumCellWidth = 504.0;
  static const double minimumCellHeight = 324.0;

  static Map<int, Rect> arrange({
    required List<DesktopOverviewItem> items,
    required Rect bounds,
  }) {
    if (items.isEmpty || bounds.width <= 0.0 || bounds.height <= 0.0) {
      return const <int, Rect>{};
    }

    final padding = math.min(
      outerPadding,
      math.min(bounds.width, bounds.height) * 0.08,
    );
    final available = bounds.deflate(padding);
    if (available.width <= 0.0 || available.height <= 0.0) {
      return const <int, Rect>{};
    }

    final ordered = List<DesktopOverviewItem>.of(items);
    _sortSpatially(ordered, available);

    _OverviewCandidate? best;
    for (var rowCount = 1; rowCount <= ordered.length; rowCount += 1) {
      final rows = _partitionRows(ordered, rowCount);
      final candidate = _layoutRows(rows, available);
      if (candidate == null || best == null || candidate.score > best.score) {
        best = candidate;
      }
    }
    return best?.frames ?? const <int, Rect>{};
  }

  static void _sortSpatially(
    List<DesktopOverviewItem> items,
    Rect available,
  ) {
    final approximateCellHeight = math.sqrt(
      available.width * available.height / math.max(1, items.length),
    );
    final rowBand = math.max(1.0, approximateCellHeight * 0.54);
    items.sort((left, right) {
      final leftBand =
          ((left.frame.center.dy - available.top) / rowBand).floor();
      final rightBand =
          ((right.frame.center.dy - available.top) / rowBand).floor();
      final bandOrder = leftBand.compareTo(rightBand);
      if (bandOrder != 0) {
        return bandOrder;
      }
      final horizontalOrder =
          left.frame.center.dx.compareTo(right.frame.center.dx);
      if (horizontalOrder != 0) {
        return horizontalOrder;
      }
      final verticalOrder =
          left.frame.center.dy.compareTo(right.frame.center.dy);
      if (verticalOrder != 0) {
        return verticalOrder;
      }
      return left.z.compareTo(right.z);
    });
  }

  static List<List<DesktopOverviewItem>> _partitionRows(
    List<DesktopOverviewItem> items,
    int rowCount,
  ) {
    final rows = <List<DesktopOverviewItem>>[];
    var start = 0;
    var remainingAspect = items.fold<double>(
      0.0,
      (sum, item) => sum + item.aspectRatio,
    );

    for (var row = 0; row < rowCount; row += 1) {
      final remainingRows = rowCount - row;
      final maximumEnd = items.length - (remainingRows - 1);
      if (remainingRows == 1) {
        rows.add(items.sublist(start));
        break;
      }

      final targetAspect = remainingAspect / remainingRows;
      var end = start + 1;
      var rowAspect = items[start].aspectRatio;
      while (end < maximumEnd) {
        final nextAspect = items[end].aspectRatio;
        if ((rowAspect + nextAspect - targetAspect).abs() >
            (rowAspect - targetAspect).abs()) {
          break;
        }
        rowAspect += nextAspect;
        end += 1;
      }

      rows.add(items.sublist(start, end));
      start = end;
      remainingAspect -= rowAspect;
    }
    return rows;
  }

  static _OverviewCandidate? _layoutRows(
    List<List<DesktopOverviewItem>> rows,
    Rect available,
  ) {
    final verticalGaps = gap * math.max(0, rows.length - 1);
    final heightForWindows = available.height - verticalGaps;
    if (heightForWindows <= 0.0) {
      return null;
    }

    final naturalHeights = <double>[];
    for (final row in rows) {
      final horizontalGaps = gap * math.max(0, row.length - 1);
      final widthForWindows = available.width - horizontalGaps;
      if (widthForWindows <= 0.0) {
        return null;
      }
      final aspectSum = row.fold<double>(
        0.0,
        (sum, item) => sum + item.aspectRatio,
      );
      naturalHeights.add(widthForWindows / aspectSum);
    }

    final naturalHeightSum =
        naturalHeights.fold<double>(0.0, (sum, height) => sum + height);
    if (naturalHeightSum <= 0.0) {
      return null;
    }
    // Rows are initially measured to fill the available width. That may be
    // larger than a window's current frame, so cap the common cell scale by
    // every source frame as well as the available height. Tiny windows reserve
    // a useful minimum footprint instead of collapsing the whole grid.
    var scale = math.min(1.0, heightForWindows / naturalHeightSum);
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      final naturalHeight = naturalHeights[rowIndex];
      for (final item in rows[rowIndex]) {
        final sourceHeight = _sourcePreviewHeight(item);
        if (!sourceHeight.isFinite) {
          continue;
        }
        final minimumHeight = math.max(
          minimumCellHeight,
          minimumCellWidth / item.aspectRatio,
        );
        final cellHeight = math.max(sourceHeight, minimumHeight);
        scale = math.min(scale, cellHeight / naturalHeight);
      }
    }
    final rowHeights = <double>[
      for (final height in naturalHeights) height * scale,
    ];
    final layoutHeight =
        rowHeights.fold<double>(0.0, (sum, height) => sum + height) +
            verticalGaps;

    final frames = <int, Rect>{};
    var occupiedArea = 0.0;
    var minimumHeight = double.infinity;
    var maximumHeight = 0.0;
    var movement = 0.0;
    var top = available.top + (available.height - layoutHeight) / 2.0;

    for (var rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      final row = rows[rowIndex];
      final height = rowHeights[rowIndex];
      final rowWidth = row.fold<double>(
            0.0,
            (sum, item) => sum + item.aspectRatio * height,
          ) +
          gap * math.max(0, row.length - 1);
      var left = available.left + (available.width - rowWidth) / 2.0;

      for (final item in row) {
        final cell = Rect.fromLTWH(
          left,
          top,
          item.aspectRatio * height,
          height,
        );
        final sourceHeight = _sourcePreviewHeight(item);
        final previewHeight = sourceHeight.isFinite
            ? math.min(cell.height, sourceHeight)
            : cell.height;
        final frame = Rect.fromCenter(
          center: cell.center,
          width: item.aspectRatio * previewHeight,
          height: previewHeight,
        );
        frames[item.objectId] = frame;
        occupiedArea += frame.width * frame.height;
        movement += (frame.center - item.frame.center).distanceSquared;
        left = cell.right + gap;
      }
      minimumHeight = math.min(minimumHeight, height);
      maximumHeight = math.max(maximumHeight, height);
      top += height + gap;
    }

    final balance = maximumHeight <= 0.0
        ? 0.0
        : (minimumHeight / maximumHeight).clamp(0.0, 1.0);
    final movementScale = math.max(
        1.0,
        available.width * available.width +
            available.height * available.height);
    final normalizedMovement = movement / movementScale;
    final score = occupiedArea * (0.88 + 0.12 * balance) -
        occupiedArea * normalizedMovement * 0.002;
    return _OverviewCandidate(frames: frames, score: score);
  }

  static double _sourcePreviewHeight(DesktopOverviewItem item) {
    if (item.frame.width <= 0.0 || item.frame.height <= 0.0) {
      return double.infinity;
    }
    return math.min(
      item.frame.height,
      item.frame.width / item.aspectRatio,
    );
  }
}

class _OverviewCandidate {
  const _OverviewCandidate({required this.frames, required this.score});

  final Map<int, Rect> frames;
  final double score;
}
