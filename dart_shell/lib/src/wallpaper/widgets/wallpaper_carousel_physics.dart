import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class WallpaperCarouselPhysics extends ScrollPhysics {
  const WallpaperCarouselPhysics({super.parent});

  static const double _projectionSeconds = 0.30;
  static const int _maximumFlingPages = 3;

  @override
  WallpaperCarouselPhysics applyTo(ScrollPhysics? ancestor) {
    return WallpaperCarouselPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.6,
        stiffness: 120,
        ratio: 1.08,
      );

  @override
  double get minFlingVelocity => 110;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    if (position is! PageMetrics || position.viewportFraction <= 0) {
      return super.createBallisticSimulation(position, velocity);
    }

    final pageExtent = math.max(
      1.0,
      position.viewportDimension * position.viewportFraction,
    );
    final currentPage = position.page ?? position.pixels / pageExtent;
    var targetPage = currentPage.round();
    if (velocity.abs() >= minFlingVelocity) {
      final projectedPages = velocity.abs() / pageExtent * _projectionSeconds;
      final travelPages =
          projectedPages.ceil().clamp(1, _maximumFlingPages).toInt();
      targetPage += velocity.sign.toInt() * travelPages;
    }

    final targetPixels = (targetPage * pageExtent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((targetPixels - position.pixels).abs() < 0.5) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      targetPixels,
      velocity,
      tolerance: toleranceFor(position),
    );
  }

  @override
  bool get allowImplicitScrolling => true;
}
