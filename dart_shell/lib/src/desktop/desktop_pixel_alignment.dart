import 'package:flutter/widgets.dart';

import '../models/display_layout.dart';

typedef DesktopOutputPixelGrid = ({Rect logicalRect, double scale});

/// Returns the physical-pixel grid for one output in desktop scene coordinates.
///
/// Flutter's ambient device-pixel ratio describes the complete atlas and is
/// therefore not authoritative when outputs use different scales.
DesktopOutputPixelGrid? desktopOutputPixelGridForMonitor(
  DisplayLayout? layout,
  int monitorId,
) {
  if (layout == null) {
    return null;
  }
  for (final output in layout.outputs) {
    if (output.monitorId == monitorId &&
        output.scale.isFinite &&
        output.scale > 0.0 &&
        output.logicalRect.isFinite) {
      return (logicalRect: output.logicalRect, scale: output.scale);
    }
  }
  return null;
}

/// Aligns a desktop client's content geometry to the Flutter pixel grid.
///
/// Wayland positions are expressed in whole logical pixels. At a fractional
/// device-pixel ratio those positions can land between atlas pixels even when
/// the client buffer itself is already rendered at the correct scale. Shift
/// the complete frame so its client content, clip, and surface tree move
/// together. Stable desktop windows align the opposite content edges as well
/// so the laid-out texture always covers a whole number of physical pixels.
/// Deliberately transformed overview and switcher geometry bypasses this
/// helper at the call site and keeps filtered animation sampling.
Rect desktopPixelAlignedWindowFrame({
  required Rect frame,
  required double contentInset,
  required double devicePixelRatio,
  required bool enabled,
  Offset pixelGridOrigin = Offset.zero,
  bool alignSize = false,
}) {
  if (!enabled ||
      frame.isEmpty ||
      !contentInset.isFinite ||
      contentInset < 0.0 ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0.0 ||
      !pixelGridOrigin.dx.isFinite ||
      !pixelGridOrigin.dy.isFinite) {
    return frame;
  }

  final contentRect = frame.deflate(contentInset);
  if (contentRect.isEmpty) {
    return frame;
  }
  double align(double value, double origin) =>
      ((value - origin) * devicePixelRatio).roundToDouble() / devicePixelRatio +
      origin;

  final alignedLeft = align(contentRect.left, pixelGridOrigin.dx);
  final alignedTop = align(contentRect.top, pixelGridOrigin.dy);
  if (!alignSize) {
    return frame.shift(
      Offset(alignedLeft - contentRect.left, alignedTop - contentRect.top),
    );
  }

  final alignedContentRect = Rect.fromLTRB(
    alignedLeft,
    alignedTop,
    align(contentRect.right, pixelGridOrigin.dx),
    align(contentRect.bottom, pixelGridOrigin.dy),
  );
  if (alignedContentRect.isEmpty) {
    return frame;
  }
  return Rect.fromLTRB(
    alignedContentRect.left - contentInset,
    alignedContentRect.top - contentInset,
    alignedContentRect.right + contentInset,
    alignedContentRect.bottom + contentInset,
  );
}
