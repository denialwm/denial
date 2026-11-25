import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/models.dart';

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
/// together. Stable desktop windows also give the content a whole number of
/// physical pixels: the size rounded as a client rounds its buffer for a
/// fractional scale, half away from zero, wherever the window sits. Aligning
/// the opposite edges instead would take a pixel off an odd-sized window at
/// every other position, and its unscaled buffer would hang over the frame.
/// Deliberately transformed overview and switcher geometry bypasses this
/// helper at the call site and keeps filtered animation sampling.
Rect desktopPixelAlignedWindowFrame({
  required Rect frame,
  required EdgeInsets contentInsets,
  required double devicePixelRatio,
  required bool enabled,
  Offset pixelGridOrigin = Offset.zero,
  bool alignSize = false,
}) {
  if (!enabled ||
      frame.isEmpty ||
      !contentInsets.isNonNegative ||
      !contentInsets.horizontal.isFinite ||
      !contentInsets.vertical.isFinite ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0.0 ||
      !pixelGridOrigin.dx.isFinite ||
      !pixelGridOrigin.dy.isFinite) {
    return frame;
  }

  final contentRect = contentInsets.deflateRect(frame);
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

  double alignExtent(double value) =>
      (value * devicePixelRatio).roundToDouble() / devicePixelRatio;

  final alignedContentRect = Rect.fromLTWH(
    alignedLeft,
    alignedTop,
    alignExtent(contentRect.width),
    alignExtent(contentRect.height),
  );
  if (alignedContentRect.isEmpty) {
    return frame;
  }
  return contentInsets.inflateRect(alignedContentRect);
}
