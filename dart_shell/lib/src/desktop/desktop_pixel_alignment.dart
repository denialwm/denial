import 'package:flutter/widgets.dart';

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
  bool alignSize = false,
}) {
  if (!enabled ||
      frame.isEmpty ||
      !contentInset.isFinite ||
      contentInset < 0.0 ||
      !devicePixelRatio.isFinite ||
      devicePixelRatio <= 0.0) {
    return frame;
  }

  final contentRect = frame.deflate(contentInset);
  if (contentRect.isEmpty) {
    return frame;
  }
  double align(double value) =>
      (value * devicePixelRatio).roundToDouble() / devicePixelRatio;

  final alignedLeft = align(contentRect.left);
  final alignedTop = align(contentRect.top);
  if (!alignSize) {
    return frame.shift(
      Offset(alignedLeft - contentRect.left, alignedTop - contentRect.top),
    );
  }

  final alignedContentRect = Rect.fromLTRB(
    alignedLeft,
    alignedTop,
    align(contentRect.right),
    align(contentRect.bottom),
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
