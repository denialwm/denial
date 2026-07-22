import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Stable anchors used by transient desktop surfaces.
///
/// Keeping this model outside the Settings UI lets layout code consume a
/// semantic placement without knowing where it was configured or persisted.
enum ShellPopupAnchor {
  topLeft(-1, -1),
  topCenter(0, -1),
  topRight(1, -1),
  centerLeft(-1, 0),
  center(0, 0),
  centerRight(1, 0),
  bottomLeft(-1, 1),
  bottomCenter(0, 1),
  bottomRight(1, 1);

  const ShellPopupAnchor(this.horizontal, this.vertical);

  final int horizontal;
  final int vertical;

  Alignment get alignment =>
      Alignment(horizontal.toDouble(), vertical.toDouble());
}

@immutable
class ShellPopupPlacement {
  const ShellPopupPlacement({
    required this.anchor,
    required this.width,
    required this.height,
    required this.margin,
  });

  final ShellPopupAnchor anchor;
  final double width;
  final double height;
  final double margin;

  ShellPopupPlacement copyWith({
    ShellPopupAnchor? anchor,
    double? width,
    double? height,
    double? margin,
  }) {
    return ShellPopupPlacement(
      anchor: anchor ?? this.anchor,
      width: width ?? this.width,
      height: height ?? this.height,
      margin: margin ?? this.margin,
    );
  }

  /// Resolves this placement inside one output, clamping hostile persisted
  /// sizes so a surface can never become unreachable.
  Rect resolve(Rect outputBounds, {double? fixedHeight}) {
    if (outputBounds.isEmpty) {
      return Rect.zero;
    }
    final safeMargin = margin.isFinite
        ? margin.clamp(0.0, 128.0).toDouble()
        : 0.0;
    final availableWidth = math.max(0.0, outputBounds.width - safeMargin * 2);
    final availableHeight = math.max(0.0, outputBounds.height - safeMargin * 2);
    final resolvedWidth = math.min(
      availableWidth,
      width.isFinite ? math.max(0.0, width) : availableWidth,
    );
    final requestedHeight = fixedHeight ?? height;
    final resolvedHeight = math.min(
      availableHeight,
      requestedHeight.isFinite
          ? math.max(0.0, requestedHeight)
          : availableHeight,
    );
    if (resolvedWidth <= 0 || resolvedHeight <= 0) {
      return Rect.zero;
    }

    final left = switch (anchor.horizontal) {
      < 0 => outputBounds.left + safeMargin,
      > 0 => outputBounds.right - safeMargin - resolvedWidth,
      _ => outputBounds.center.dx - resolvedWidth / 2,
    };
    final top = switch (anchor.vertical) {
      < 0 => outputBounds.top + safeMargin,
      > 0 => outputBounds.bottom - safeMargin - resolvedHeight,
      _ => outputBounds.center.dy - resolvedHeight / 2,
    };
    return Rect.fromLTWH(left, top, resolvedWidth, resolvedHeight);
  }

  /// Returns an edge target adjacent to the configured surface. Corner
  /// anchors use their nearest vertical edge, preserving Denial's existing
  /// top-left and bottom-left hover affordances by default.
  Rect edgeTrigger(
    Rect outputBounds, {
    double thickness = 8,
    double extent = 96,
  }) {
    if (outputBounds.isEmpty) {
      return Rect.zero;
    }
    final safeThickness = math.min(math.max(0.0, thickness), 32.0);
    final safeExtent = math.min(
      math.max(0.0, extent),
      math.max(outputBounds.width, outputBounds.height) / 2,
    );
    if (anchor.horizontal != 0) {
      final top = switch (anchor.vertical) {
        < 0 => outputBounds.top,
        > 0 => outputBounds.bottom - safeExtent,
        _ => outputBounds.center.dy - safeExtent / 2,
      };
      final left = anchor.horizontal < 0
          ? outputBounds.left
          : outputBounds.right - safeThickness;
      return Rect.fromLTWH(left, top, safeThickness, safeExtent);
    }
    final left = outputBounds.center.dx - safeExtent / 2;
    final top = anchor.vertical > 0
        ? outputBounds.bottom - safeThickness
        : outputBounds.top;
    return Rect.fromLTWH(left, top, safeExtent, safeThickness);
  }

  @override
  bool operator ==(Object other) {
    return other is ShellPopupPlacement &&
        other.anchor == anchor &&
        other.width == width &&
        other.height == height &&
        other.margin == margin;
  }

  @override
  int get hashCode => Object.hash(anchor, width, height, margin);
}
