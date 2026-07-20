import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/services/cpu_usage_service.dart';

void main() {
  test('parses the aggregate cpu line and ignores per-core lines', () {
    const content = 'cpu  100 20 60 700 100 5 15 0 0 0\n'
        'cpu0 50 10 30 350 50 2 8 0 0 0\n'
        'intr 12345\n';

    final sample = parseProcStat(content)!;

    // total = 100+20+60+700+100+5+15+0, idle = 700+100.
    expect(sample.total, 1000);
    expect(sample.busy, 200);
  });

  test('usage is the busy fraction of the sampled delta', () {
    const previous = CpuSample(busy: 200, total: 1000);
    const next = CpuSample(busy: 260, total: 1200);

    expect(CpuSample.usageBetween(previous, next), closeTo(0.3, 1e-9));
  });

  test('stalled or wrapped counters produce no reading', () {
    const sample = CpuSample(busy: 200, total: 1000);
    const wrapped = CpuSample(busy: 100, total: 1100);

    expect(CpuSample.usageBetween(sample, sample), isNull);
    expect(CpuSample.usageBetween(sample, wrapped), isNull);
  });

  test('malformed stat contents fail closed', () {
    expect(parseProcStat(''), isNull);
    expect(parseProcStat('cpu0 1 2 3 4 5 6 7 8\n'), isNull);
    expect(parseProcStat('cpu  1 2 three 4 5 6 7 8\n'), isNull);
    expect(parseProcStat('cpu  1 2 3\n'), isNull);
  });

  test('parses Linux millidegree temperatures defensively', () {
    expect(parseLinuxTemperatureC('54500\n'), 54.5);
    expect(parseLinuxTemperatureC('61.25'), 61.25);
    expect(parseLinuxTemperatureC('not-a-sensor'), isNull);
    expect(parseLinuxTemperatureC('999000'), isNull);
  });

  test('selects and caches the preferred CPU hwmon sensor', () async {
    final root = await Directory.systemTemp.createTemp('denial-cpu-temp-');
    addTearDown(() => root.delete(recursive: true));
    final hwmon = Directory('${root.path}/hwmon/hwmon3');
    await hwmon.create(recursive: true);
    await File('${hwmon.path}/name').writeAsString('k10temp\n');
    await File('${hwmon.path}/temp1_label').writeAsString('Tccd1\n');
    await File('${hwmon.path}/temp1_input').writeAsString('68000\n');
    await File('${hwmon.path}/temp2_label').writeAsString('Tctl\n');
    final package = File('${hwmon.path}/temp2_input');
    await package.writeAsString('52500\n');

    final reader = CpuTemperatureReader(
      hwmonRoot: '${root.path}/hwmon',
      thermalRoot: '${root.path}/thermal',
    );

    expect(await reader.read(), 52.5);
    await package.writeAsString('53000\n');
    await File('${hwmon.path}/name').delete();
    expect(await reader.read(), 53.0);
  });
}
