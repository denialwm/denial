import 'package:denial_dart_shell/src/diagnostics/cursor_benchmark.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const output = DisplayOutput(
    monitorId: 3,
    name: 'test',
    logicalRect: Rect.fromLTWH(-1600, 200, 1600, 900),
    pixelSize: Size(2400, 1350),
    scale: 1.5,
    refreshRate: 120,
  );

  test(
    'circle keeps its phase after missed ticks and repeated revolutions',
    () {
      final circle = CursorCircle.fromJson({'radius': 100}, output);
      expect(circle.center, const Offset(-800, 650));
      expect(circle.at(Duration.zero), const Offset(-700, 650));
      final quarter = circle.at(const Duration(milliseconds: 500));
      expect(quarter.dx, closeTo(-800, 0.00001));
      expect(quarter.dy, closeTo(750, 0.00001));
      expect(circle.at(const Duration(milliseconds: 6500)), quarter);
      expect(circle.totalUs, 35000000);
    },
  );

  test('circle refuses to cross the output or accept unbounded workloads', () {
    for (final request in <Map<String, dynamic>>[
      {'radius': 500},
      {'center_x': -1580},
      {'radius': double.nan},
      {'period_seconds': 0},
      {'duration_seconds': 121},
      {'warmup_seconds': -1},
      {'duration_seconds': '30'},
    ]) {
      expect(() => CursorCircle.fromJson(request, output), throwsArgumentError);
    }
  });
}
