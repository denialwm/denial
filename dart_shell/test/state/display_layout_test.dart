import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';

void main() {
  test('main output follows the explicitly configured shell output', () {
    final right = _output(0, 'right', 2560);
    final left = _output(1, 'left', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[right, left],
      tickerMonitorId: 0,
      systemBarMonitorId: 1,
    );

    expect(layout.mainOutput, same(left));
  });

  test('main output falls back to the ticker and then the leftmost output', () {
    final right = _output(0, 'right', 2560);
    final left = _output(1, 'left', 0);

    expect(
      _layout(
        outputs: <DisplayOutput>[right, left],
        tickerMonitorId: 0,
        systemBarMonitorId: 99,
      ).mainOutput,
      same(right),
    );
    expect(
      _layout(
        outputs: <DisplayOutput>[right, left],
        tickerMonitorId: 98,
        systemBarMonitorId: 99,
      ).mainOutput,
      same(left),
    );
  });

  test('system bar strip and work area split the configured output', () {
    final right = _output(0, 'right', 2560);
    final left = _output(1, 'left', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[right, left],
      tickerMonitorId: 0,
      systemBarMonitorId: 1,
      systemBarSide: SystemBarSide.top,
      systemBarThickness: 32,
    );

    expect(layout.systemBarActive, isTrue);
    expect(layout.systemBarRect, const Rect.fromLTWH(0, 0, 2560, 32));
    expect(layout.workAreaOf(left), const Rect.fromLTRB(0, 32, 2560, 1440));
    expect(layout.workAreaOf(right), right.logicalRect);
    expect(layout.workAreasByMonitor(), <int, Rect>{
      0: right.logicalRect,
      1: const Rect.fromLTRB(0, 32, 2560, 1440),
    });
  });

  test('selected outputs receive independent cloned bars and work areas', () {
    final right = _output(0, 'right', 2560);
    final left = _output(1, 'left', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[right, left],
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      systemBarMonitorIds: const <int>[0, 1],
      systemBarSide: SystemBarSide.bottom,
      systemBarThickness: 32,
    );

    expect(layout.systemBarOutputs, <DisplayOutput>[right, left]);
    expect(
      layout.systemBarRectFor(right),
      const Rect.fromLTWH(2560, 1408, 2560, 32),
    );
    expect(
      layout.systemBarRectFor(left),
      const Rect.fromLTWH(0, 1408, 2560, 32),
    );
    expect(layout.workAreaOf(right), const Rect.fromLTWH(2560, 0, 2560, 1408));
    expect(layout.workAreaOf(left), const Rect.fromLTWH(0, 0, 2560, 1408));
  });

  test('hidden or zero-thickness bars reserve no work area', () {
    final only = _output(0, 'only', 0);
    final hidden = _layout(
      outputs: <DisplayOutput>[only],
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      systemBarSide: SystemBarSide.hidden,
      systemBarThickness: 32,
    );
    final zero = _layout(
      outputs: <DisplayOutput>[only],
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      systemBarSide: SystemBarSide.top,
    );

    for (final layout in [hidden, zero]) {
      expect(layout.systemBarActive, isFalse);
      expect(layout.systemBarRect, Rect.zero);
      expect(layout.workAreaOf(only), only.logicalRect);
    }
  });

  test('oversized bar thickness never swallows the output', () {
    final only = _output(0, 'only', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[only],
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      systemBarSide: SystemBarSide.bottom,
      systemBarThickness: 5000,
    );

    expect(layout.systemBarRect, const Rect.fromLTRB(0, 720, 2560, 1440));
    expect(layout.workAreaOf(only), const Rect.fromLTRB(0, 0, 2560, 720));
  });

  test('maximize padding insets every bar-free edge', () {
    final right = _output(0, 'right', 2560);
    final left = _output(1, 'left', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[right, left],
      tickerMonitorId: 0,
      systemBarMonitorId: 1,
      systemBarSide: SystemBarSide.top,
      systemBarThickness: 32,
      maximizePadding: 10,
    );

    // The bar edge keeps only the bar; the other three edges gain padding.
    expect(layout.workAreaOf(left), const Rect.fromLTRB(10, 32, 2550, 1430));
    // Outputs without the bar pad all four edges.
    expect(layout.workAreaOf(right), const Rect.fromLTRB(2570, 10, 5110, 1430));
  });

  test('hidden bars still apply maximize padding on all edges', () {
    final only = _output(0, 'only', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[only],
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      maximizePadding: 10,
    );

    expect(layout.workAreaOf(only), const Rect.fromLTRB(10, 10, 2550, 1430));
  });

  test('oversized maximize padding never swallows the output', () {
    final only = _output(0, 'only', 0);
    final layout = _layout(
      outputs: <DisplayOutput>[only],
      tickerMonitorId: 0,
      systemBarMonitorId: 0,
      maximizePadding: 10000,
    );

    // Clamped to a quarter of the smaller output dimension per side.
    expect(layout.workAreaOf(only), const Rect.fromLTRB(360, 360, 2200, 1080));
  });
}

DisplayOutput _output(int monitorId, String name, double left) {
  return DisplayOutput(
    monitorId: monitorId,
    name: name,
    logicalRect: Rect.fromLTWH(left, 0, 2560, 1440),
    pixelSize: const Size(2560, 1440),
    scale: 1,
    refreshRate: 120,
  );
}

DisplayLayout _layout({
  required List<DisplayOutput> outputs,
  required int tickerMonitorId,
  required int systemBarMonitorId,
  List<int> systemBarMonitorIds = const <int>[],
  SystemBarSide systemBarSide = SystemBarSide.left,
  double systemBarThickness = 0.0,
  double maximizePadding = 0.0,
}) {
  return DisplayLayout(
    epoch: 1,
    globalOrigin: Offset.zero,
    logicalSize: const Size(5120, 1440),
    pixelSize: const Size(5120, 1440),
    engineScale: 1,
    tickerMonitorId: tickerMonitorId,
    systemBarMonitorId: systemBarMonitorId,
    systemBarMonitorIds: systemBarMonitorIds,
    systemBarSide: systemBarSide,
    systemBarThickness: systemBarThickness,
    maximizePadding: maximizePadding,
    outputs: outputs,
  );
}
