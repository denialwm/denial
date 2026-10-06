import 'package:flutter/widgets.dart';

import 'shade/shade_reference_geometry.dart';

/// Resolves painted mobile dimensions independently of reference-page scale.
///
/// The ColorOS shade lays out against a fixed reference viewport and scales
/// that viewport to the device. Text is already counter-scaled by its
/// [MediaQuery]. Mobile artwork, insets, controls, and radii must use
/// [visual] for the same reason or their apparent size changes between a
/// heads-up notification and the notification shade.
final class MobileUiMetrics {
  const MobileUiMetrics._(this._visualScale);

  factory MobileUiMetrics.of(BuildContext context) =>
      MobileUiMetrics._(ShadeReferenceGeometry.inverseScaleOf(context));

  final double _visualScale;

  double visual(double dimension) => dimension * _visualScale;

  EdgeInsets visualInsets({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) => EdgeInsets.fromLTRB(
    visual(left),
    visual(top),
    visual(right),
    visual(bottom),
  );
}

/// The canonical notification measurements for Denial mobile UI.
///
/// Text sizes are logical font sizes because the shade's [MediaQuery]
/// resolves them. Other content dimensions are passed through
/// [MobileUiMetrics.visual] at the point of use.
abstract final class MobileNotificationMetrics {
  static const double horizontalMargin = 16;
  static const double rowSpacing = 10;

  static const double horizontalContentInset = 20;
  static const double verticalContentInset = 20;
  static const double leadingArtwork = 56;
  static const double contentArtwork = 48;
  static const double leadingGap = 14;
  static const double contentGap = 12;

  static const double titleFontSize = 20;
  static const double bodyFontSize = 18;
  static const double copySpacing = 4;
  static const double sectionSpacing = 11;
  static const double progressHeight = 3;

  static const double actionHeight = 48;
  static const double actionMinimumWidth = 48;
  static const double actionHorizontalInset = 12;
  static const double actionSpacing = 7;
  static const double actionRadius = 12;
  static const double actionFontSize = 17;

  static const double detailsExtent = 48;
  static const double detailsIcon = 22;

  static const double dismissExtent = 30;
  static const double dismissIcon = 17;
  static const double dismissRadius = 11;

  static const double clearActionHeight = 48;
  static const double clearActionHorizontalInset = 12;
  static const double clearActionSpacing = 8;
  static const double clearActionFontSize = 16;
  static const double clearActionIcon = 24;
}
