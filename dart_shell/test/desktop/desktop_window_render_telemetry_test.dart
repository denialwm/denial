import 'dart:ui' show FrameTiming;

import 'package:denial_dart_shell/src/desktop/desktop_window_render_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frame timing audit reports interval tails and over-budget counts', () {
    final audit = FrameTimingAuditInterval();
    audit.record(<FrameTiming>[
      _timing(vsyncStart: 0, buildUs: 100, rasterUs: 400),
      _timing(vsyncStart: 10000, buildUs: 200, rasterUs: 300),
      _timing(vsyncStart: 30000, buildUs: 300, rasterUs: 200),
      _timing(vsyncStart: 40000, buildUs: 400, rasterUs: 100),
    ]);

    final report = audit.takeReport(budgetUs: 450);

    expect(report['frames'], 4);
    expect(report['build_avg_us'], 250);
    expect(report['build_p50_us'], 200);
    expect(report['build_p95_us'], 400);
    expect(report['build_p99_us'], 400);
    expect(report['build_max_us'], 400);
    expect(report['raster_queue_p95_us'], 50);
    expect(report['engine_work_p99_us'], 500);
    expect(report['engine_over_budget'], 4);
    expect(report['vsync_gap_p50_us'], 10000);
    expect(report['vsync_gap_p95_us'], 20000);
    expect(report['vsync_gap_over_budget'], 3);
  });

  test('report reset retains only the cross-interval cadence edge', () {
    final audit = FrameTimingAuditInterval();
    audit.record(<FrameTiming>[
      _timing(vsyncStart: 1000, buildUs: 100, rasterUs: 100),
    ]);
    audit.takeReport(budgetUs: 10000);

    audit.record(<FrameTiming>[
      _timing(vsyncStart: 11000, buildUs: 200, rasterUs: 300),
    ]);
    final report = audit.takeReport(budgetUs: 10000);

    expect(report['frames'], 1);
    expect(report['build_avg_us'], 200);
    expect(report['vsync_gap_avg_us'], 10000);
  });
}

FrameTiming _timing({
  required int vsyncStart,
  required int buildUs,
  required int rasterUs,
}) {
  final buildStart = vsyncStart + 10;
  final buildFinish = buildStart + buildUs;
  final rasterStart = buildFinish + 50;
  final rasterFinish = rasterStart + rasterUs;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
  );
}
