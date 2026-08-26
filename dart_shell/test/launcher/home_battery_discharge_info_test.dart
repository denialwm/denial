import 'dart:io';

import 'package:denial_dart_shell/src/launcher/models/home_battery_discharge_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('graph view model caches filtering, extrema, average, and scale', () {
    final series = HomeBatteryDischargeSeries.parse('''
ts_ms\tmono_ms\tstate\tcapacity\tcurrent_ma\tvoltage_mv\tpower_mw
1000\t0\tdischarging\t80\t-100\t4000\t400
2000\t0\tdischarging\t80\tunknown\t4000\tunknown
3000\t0\tdischarging\t79\t-300\t3990\t1197
4000\t0\tdischarging\t79\t-200\t3980\t796
''');

    final graph = series.graph;
    expect(graph.points.map((point) => point.drawMa), <int>[100, 300, 200]);
    expect(graph.minIndex, 0);
    expect(graph.maxIndex, 1);
    expect(graph.latestIndex, 2);
    expect(graph.averageDrawMa, 200);
    expect(graph.scaleMaxMa, 300);
    expect(identical(series.graph, graph), isTrue);
  });

  test('tail reader parses only completed appended lines', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-battery-tail-',
    );
    final file = File('${directory.path}/battery_discharge.tsv');
    await file.writeAsString('''
ts_ms\tmono_ms\tstate\tcapacity\tcurrent_ma\tvoltage_mv\tpower_mw
1000\t0\tdischarging\t80\t-100\t4000\t400
''');
    final reader = HomeBatteryDischargeTailReader(
      file: file,
      eventDebounce: Duration.zero,
      recoveryInterval: const Duration(hours: 1),
    );
    final snapshots = <HomeBatteryDischargeSeries>[];
    final subscription = reader.snapshots.listen(snapshots.add);
    addTearDown(() async {
      await subscription.cancel();
      await reader.dispose();
      await directory.delete(recursive: true);
    });

    await _waitUntil(() => snapshots.length == 1);
    expect(snapshots.single.points, hasLength(1));

    await file.writeAsString(
      '2000\t0\tdischarging\t79\t-240',
      mode: FileMode.append,
      flush: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(snapshots, hasLength(1));

    await file.writeAsString(
      '\t3990\t958\n',
      mode: FileMode.append,
      flush: true,
    );
    await _waitUntil(() => snapshots.length == 2);
    expect(snapshots.last.points, hasLength(2));
    expect(snapshots.last.latest?.drawMa, 240);
  });

  test('dispose cannot leave an asynchronous watch setup active', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-battery-watch-dispose-',
    );
    final file = File('${directory.path}/battery_discharge.tsv');
    await file.writeAsString('');
    final reader = HomeBatteryDischargeTailReader(
      file: file,
      recoveryInterval: const Duration(hours: 1),
    );
    final subscription = reader.snapshots.listen((_) {});

    await reader.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(reader.debugHasActiveWatch, isFalse);
    await subscription.cancel();
    await directory.delete(recursive: true);
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for a battery history update.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
