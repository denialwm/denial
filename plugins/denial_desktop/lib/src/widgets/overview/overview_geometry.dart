import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/rendering.dart';

// Launcher3 Quickstep's overview_page_spacing. Its overview_max_scale is 0.7;
// Denial's recents previews are 10% smaller, leaving room for their labels.
const double overviewMaxScale = 0.63;
const double overviewPageSpacing = 16.0;

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
    0.0,
    constraints.maxHeight - padding.vertical,
  );
  final maxWidth = availableWidth * overviewMaxScale;
  final maxHeight = math.min(
    availableHeight,
    constraints.maxHeight * overviewMaxScale,
  );

  var width = maxWidth;
  var height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }

  return Size(width, height);
}

/// Keep the page stride tied to the preview, including on tall or inset views.
/// A fixed viewport fraction changes the visible gap as the card is fitted.
/// The carousel paints an extra page on each side during dismissal reflow.
double overviewPageViewportFractionFor(Size viewSize, EdgeInsets padding) {
  if (viewSize.width <= 0) return 1;
  final cardSize = cardSizeFor(
    constraints: BoxConstraints.tight(viewSize),
    padding: padding,
    aspect: viewAspectFor(viewSize),
  );
  return ((cardSize.width + overviewPageSpacing) /
          overviewCarouselViewportWidthFor(viewSize, cardSize))
      .clamp(0.01, 1.0);
}

/// Slivers only paint children inside their viewport, even if cached. Extend
/// it by one page on either side, then clip to the actual screen in the widget,
/// so a translated neighbor can enter the screen before its slot is removed.
double overviewCarouselViewportWidthFor(Size viewSize, Size cardSize) =>
    viewSize.width + 2 * (cardSize.width + overviewPageSpacing);

/// The centred rect a preview card occupies when the overview is fully open.
Rect centerPreviewRectFor(Size viewSize, Size cardSize) {
  final left = (viewSize.width - cardSize.width) / 2.0;
  final top = (viewSize.height - cardSize.height) / 2.0;
  return Rect.fromLTWH(left, top, cardSize.width, cardSize.height);
}
