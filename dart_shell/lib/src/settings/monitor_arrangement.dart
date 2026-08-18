import 'dart:math' as math;
import 'dart:ui';

/// The default canvas scale and snap distance used by nwg-displays.
///
/// Denial caps its automatic canvas scale at the same 0.15 value and shrinks
/// it only when the complete arrangement would otherwise be clipped.
const double nwgDisplaysViewScale = 0.15;
const double nwgDisplaysMinViewScale = 0.10;
const double nwgDisplaysMaxViewScale = 0.60;
const double nwgDisplaysSnapThreshold = 10;
const double denialMinMonitorViewScale = 0.01;
const int denialMaxOutputCoordinate = 0x7fffffff;

/// Denial's non-negative output-coordinate domain at the current canvas zoom.
///
/// The native output-control protocol represents both axes as signed 32-bit
/// integers. The settings editor intentionally uses their non-negative half.
Size denialMonitorWorkspaceSize(double viewScale) {
  assert(viewScale > 0);
  return Size.square(denialMaxOutputCoordinate * viewScale);
}

class MonitorArrangementGeometry {
  const MonitorArrangementGeometry({
    required this.name,
    required this.x,
    required this.y,
    required this.logicalSize,
  });

  final String name;
  final int x;
  final int y;
  final Size logicalSize;
}

/// Resolves a monitor drag with nwg-displays' arrangement behavior.
///
/// The candidate is expressed in canvas pixels, just like GTK's fixed-widget
/// motion event. It is constrained to the non-negative canvas, then its
/// leading and trailing edges are snapped independently to zero and every
/// edge of every other monitor. The trailing edge has precedence when both
/// edges are within the threshold, matching nwg-displays.
///
/// Reference: nwg-displays `on_motion_notify_event`, master revision
/// 6f48fc2240387d489ea775d90456e198711f0792.
math.Point<int> arrangeMonitorLikeNwgDisplays({
  required String movingName,
  required Offset candidateCanvasPosition,
  required Size canvasSize,
  required double viewScale,
  required List<MonitorArrangementGeometry> monitors,
  double snapThreshold = nwgDisplaysSnapThreshold,
}) {
  assert(viewScale > 0);
  final moving = monitors.firstWhere((monitor) => monitor.name == movingName);
  final width = moving.logicalSize.width * viewScale;
  final height = moving.logicalSize.height * viewScale;
  final maxX = math.max(0.0, canvasSize.width - width).floorToDouble();
  final maxY = math.max(0.0, canvasSize.height - height).floorToDouble();
  var x = _roundToNwgPixel(
    candidateCanvasPosition.dx.clamp(0.0, maxX).toDouble(),
  );
  var y = _roundToNwgPixel(
    candidateCanvasPosition.dy.clamp(0.0, maxY).toDouble(),
  );

  final snapX = <double>[0];
  final snapY = <double>[0];
  for (final monitor in monitors) {
    if (monitor.name == movingName) {
      continue;
    }
    _addUnique(snapX, monitor.x * viewScale);
    _addUnique(snapX, (monitor.x + monitor.logicalSize.width) * viewScale);
    _addUnique(snapY, monitor.y * viewScale);
    _addUnique(snapY, (monitor.y + monitor.logicalSize.height) * viewScale);
  }

  double? snappedX;
  double? snappedY;
  for (final line in snapX) {
    if ((x - line).abs() < snapThreshold) {
      snappedX = line;
      break;
    }
  }
  for (final line in snapX) {
    if ((x + width - line).abs() < snapThreshold) {
      snappedX = line - width;
      break;
    }
  }
  for (final line in snapY) {
    if ((y - line).abs() < snapThreshold) {
      snappedY = line;
      break;
    }
  }
  for (final line in snapY) {
    if ((y + height - line).abs() < snapThreshold) {
      snappedY = line - height;
      break;
    }
  }

  x = math.max(0.0, snappedX ?? x);
  y = math.max(0.0, snappedY ?? y);
  return math.Point<int>((x / viewScale).round(), (y / viewScale).round());
}

/// Converts nwg-displays' configurable snap margin into canvas pixels.
///
/// `on_view_scale_changed` scales the configured margin with the current view
/// scale so snapping feels consistent as the monitor widgets are resized.
double nwgDisplaysScaledSnapThreshold(double viewScale) {
  return (nwgDisplaysSnapThreshold * viewScale / nwgDisplaysMinViewScale)
      .roundToDouble();
}

/// Finds a view scale that presents the complete monitor topology.
///
/// NWG's regular zoom range bottoms out at 0.10. Denial's explicit Fit action
/// may go lower so even a wall of ten vertically stacked displays remains
/// inspectable without changing their logical coordinates.
double fitMonitorCanvasScale({
  required Size viewportSize,
  required Size layoutExtent,
  double maximumScale = nwgDisplaysMaxViewScale,
  double minimumScale = denialMinMonitorViewScale,
}) {
  final horizontal = viewportSize.width / math.max(1, layoutExtent.width);
  final vertical = viewportSize.height / math.max(1, layoutExtent.height);
  return math.min(
    maximumScale,
    math.max(minimumScale, math.min(horizontal, vertical)),
  );
}

/// Centers the topology inside the current canvas viewport.
Offset centerMonitorCanvasPan({
  required Size viewportSize,
  required Size contentSize,
}) {
  return Offset(
    (viewportSize.width - contentSize.width) / 2,
    (viewportSize.height - contentSize.height) / 2,
  );
}

/// Preserves the logical point at the viewport center while changing zoom.
Offset panMonitorCanvasForZoom({
  required Offset pan,
  required Size viewportSize,
  required double oldScale,
  required double newScale,
  Offset? viewportAnchor,
}) {
  assert(oldScale > 0);
  assert(newScale > 0);
  final anchor =
      viewportAnchor ?? Offset(viewportSize.width / 2, viewportSize.height / 2);
  final logicalAnchor = Offset(
    (anchor.dx - pan.dx) / oldScale,
    (anchor.dy - pan.dy) / oldScale,
  );
  return Offset(
    anchor.dx - logicalAnchor.dx * newScale,
    anchor.dy - logicalAnchor.dy * newScale,
  );
}

double _roundToNwgPixel(double value) {
  final lower = value.floorToDouble();
  return value - lower > 0.5 ? lower + 1 : lower;
}

void _addUnique(List<double> values, double value) {
  if (!values.contains(value)) {
    values.add(value);
  }
}
