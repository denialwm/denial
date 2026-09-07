import 'dart:ui' show SemanticsAction;

import 'package:flutter/widgets.dart';

/// Lets a fling coast freely across tasks, then centers the nearest preview.
class OverviewScrollPhysics extends ClampingScrollPhysics {
  const OverviewScrollPhysics({super.parent});

  @override
  OverviewScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      OverviewScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    if (position is! PageMetrics ||
        position.outOfRange ||
        velocity.abs() >= tolerance.velocity) {
      return super.createBallisticSimulation(position, velocity);
    }
    final stride = position.viewportDimension * position.viewportFraction;
    if (stride <= 0) return null;
    final page = position.page;
    if (page == null) return null;
    final target = (position.pixels + (page.roundToDouble() - page) * stride)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    // Flutter re-enters ballistics with zero velocity when the free fling
    // ends. Settle only then, rather than choosing the next page on release.
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// Keeps moving recents interactive so a tap can stop paging and select a task.
class OverviewPageController extends PageController {
  OverviewPageController({
    super.initialPage,
    super.keepPage,
    super.viewportFraction,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => super.createScrollPosition(
    physics,
    _InteractiveScrollContext(context),
    oldPosition,
  );
}

class _InteractiveScrollContext implements ScrollContext {
  _InteractiveScrollContext(this.delegate);

  final ScrollContext delegate;

  // Scrollable normally excludes its children from hit testing while coasting.
  // Recents must hit the preview under the initial contact, before Scrollable
  // holds the animation. The gesture arena still cancels taps on actual drags.
  @override
  void setIgnorePointer(bool value) => delegate.setIgnorePointer(false);

  @override
  BuildContext? get notificationContext => delegate.notificationContext;

  @override
  BuildContext get storageContext => delegate.storageContext;

  @override
  TickerProvider get vsync => delegate.vsync;

  @override
  AxisDirection get axisDirection => delegate.axisDirection;

  @override
  double get devicePixelRatio => delegate.devicePixelRatio;

  @override
  void setCanDrag(bool value) => delegate.setCanDrag(value);

  @override
  void setSemanticsActions(Set<SemanticsAction> actions) =>
      delegate.setSemanticsActions(actions);

  @override
  void saveOffset(double offset) => delegate.saveOffset(offset);
}
