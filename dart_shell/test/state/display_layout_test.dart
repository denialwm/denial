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
}) {
  return DisplayLayout(
    epoch: 1,
    globalOrigin: Offset.zero,
    logicalSize: const Size(5120, 1440),
    pixelSize: const Size(5120, 1440),
    engineScale: 1,
    tickerMonitorId: tickerMonitorId,
    systemBarMonitorId: systemBarMonitorId,
    systemBarSide: SystemBarSide.left,
    outputs: outputs,
  );
}
