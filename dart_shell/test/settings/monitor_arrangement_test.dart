import 'dart:ui';

import 'package:denial_dart_shell/src/settings/monitor_arrangement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const moving = MonitorArrangementGeometry(
    name: 'DP-1',
    x: 0,
    y: 0,
    logicalSize: Size(100, 100),
  );

  test('clamps the dragged monitor inside the non-negative canvas', () {
    final left = arrangeMonitorLikeNwgDisplays(
      movingName: moving.name,
      candidateCanvasPosition: const Offset(-40, -20),
      canvasSize: const Size(500, 400),
      viewScale: 1,
      monitors: const <MonitorArrangementGeometry>[moving],
    );
    final bottomRight = arrangeMonitorLikeNwgDisplays(
      movingName: moving.name,
      candidateCanvasPosition: const Offset(480, 370),
      canvasSize: const Size(500, 400),
      viewScale: 1,
      monitors: const <MonitorArrangementGeometry>[moving],
    );

    expect(left.x, 0);
    expect(left.y, 0);
    expect(bottomRight.x, 400);
    expect(bottomRight.y, 300);
  });

  test('snaps both monitor edges independently to neighboring edges', () {
    const anchor = MonitorArrangementGeometry(
      name: 'HDMI-A-1',
      x: 300,
      y: 200,
      logicalSize: Size(200, 150),
    );
    final position = arrangeMonitorLikeNwgDisplays(
      movingName: moving.name,
      candidateCanvasPosition: const Offset(194, 203),
      canvasSize: const Size(800, 600),
      viewScale: 1,
      monitors: const <MonitorArrangementGeometry>[moving, anchor],
    );

    expect(position.x, 200);
    expect(position.y, 200);
  });

  test('uses a strict ten-pixel threshold and snaps to coordinate zero', () {
    final inside = arrangeMonitorLikeNwgDisplays(
      movingName: moving.name,
      candidateCanvasPosition: const Offset(9, 9),
      canvasSize: const Size(500, 400),
      viewScale: 1,
      monitors: const <MonitorArrangementGeometry>[moving],
    );
    final boundary = arrangeMonitorLikeNwgDisplays(
      movingName: moving.name,
      candidateCanvasPosition: const Offset(10, 10),
      canvasSize: const Size(500, 400),
      viewScale: 1,
      monitors: const <MonitorArrangementGeometry>[moving],
    );

    expect(inside.x, 0);
    expect(inside.y, 0);
    expect(boundary.x, 10);
    expect(boundary.y, 10);
  });

  test('gives the trailing edge precedence like nwg-displays', () {
    const anchor = MonitorArrangementGeometry(
      name: 'HDMI-A-1',
      x: 108,
      y: 200,
      logicalSize: Size(100, 100),
    );
    final position = arrangeMonitorLikeNwgDisplays(
      movingName: moving.name,
      candidateCanvasPosition: const Offset(5, 50),
      canvasSize: const Size(500, 400),
      viewScale: 1,
      monitors: const <MonitorArrangementGeometry>[moving, anchor],
    );

    expect(position.x, 8);
    expect(position.y, 50);
  });

  test('scales the snap margin with NWG view zoom', () {
    expect(nwgDisplaysScaledSnapThreshold(0.10), 10);
    expect(nwgDisplaysScaledSnapThreshold(0.15), 15);
    expect(nwgDisplaysScaledSnapThreshold(0.60), 60);
  });

  test('uses Denial signed-32-bit output coordinates as its workspace', () {
    final workspace = denialMonitorWorkspaceSize(0.15);

    expect(denialMaxOutputCoordinate, 0x7fffffff);
    expect(workspace.width, 0x7fffffff * 0.15);
    expect(workspace.height, workspace.width);
  });

  test('fits ten vertically stacked monitors below the regular zoom range', () {
    final scale = fitMonitorCanvasScale(
      viewportSize: const Size(900, 340),
      layoutExtent: const Size(1920, 10800),
    );

    expect(scale, closeTo(340 / 10800, 0.000001));
    expect(scale, lessThan(nwgDisplaysMinViewScale));
    expect(denialMinMonitorViewScale, 0.01);
  });

  test('keeps the canvas center stable while changing zoom', () {
    const viewport = Size(900, 340);
    const pan = Offset(-120, -40);
    final before = Offset(
      (viewport.width / 2 - pan.dx) / 0.15,
      (viewport.height / 2 - pan.dy) / 0.15,
    );
    final next = panMonitorCanvasForZoom(
      pan: pan,
      viewportSize: viewport,
      oldScale: 0.15,
      newScale: 0.20,
    );
    final after = Offset(
      (viewport.width / 2 - next.dx) / 0.20,
      (viewport.height / 2 - next.dy) / 0.20,
    );

    expect(after.dx, closeTo(before.dx, 0.000001));
    expect(after.dy, closeTo(before.dy, 0.000001));
  });

  test('keeps the logical point below the mouse stable while zooming', () {
    const viewport = Size(900, 340);
    const pan = Offset(-120, -40);
    const anchor = Offset(120, 80);
    final before = Offset(
      (anchor.dx - pan.dx) / 0.15,
      (anchor.dy - pan.dy) / 0.15,
    );
    final next = panMonitorCanvasForZoom(
      pan: pan,
      viewportSize: viewport,
      oldScale: 0.15,
      newScale: 0.20,
      viewportAnchor: anchor,
    );
    final after = Offset(
      (anchor.dx - next.dx) / 0.20,
      (anchor.dy - next.dy) / 0.20,
    );

    expect(after.dx, closeTo(before.dx, 0.000001));
    expect(after.dy, closeTo(before.dy, 0.000001));
  });
}
