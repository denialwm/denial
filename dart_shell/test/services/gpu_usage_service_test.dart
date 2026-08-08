import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/services/gpu_usage_service.dart';

void main() {
  group('parseGpuBusyPercent', () {
    test('parses and clamps the integer percentage', () {
      expect(parseGpuBusyPercent('37\n'), 0.37);
      expect(parseGpuBusyPercent('0'), 0.0);
      expect(parseGpuBusyPercent('250'), 1.0);
    });

    test('fails closed on malformed contents', () {
      expect(parseGpuBusyPercent(''), isNull);
      expect(parseGpuBusyPercent('N/A'), isNull);
    });
  });

  group('disambiguateGpuLabels', () {
    test('suffixes duplicated vendor tags in order', () {
      final samples = disambiguateGpuLabels(const [
        GpuSample(id: 'card0', label: 'NV', usage: 0.1, temperatureC: 51),
        GpuSample(id: 'card1', label: 'AMD', usage: 0.2),
        GpuSample(id: 'card2', label: 'NV', usage: 0.3),
      ]);

      expect(samples.map((s) => s.label), ['NV0', 'AMD', 'NV1']);
      expect(samples.first.temperatureC, 51);
    });
  });

  group('GpuUsageService', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('denial-drm-');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    Future<void> card(
      String name, {
      String? busy,
      String vendor = '0x1002',
    }) async {
      final device = Directory('${root.path}/$name/device');
      await device.create(recursive: true);
      await File('${device.path}/vendor').writeAsString('$vendor\n');
      if (busy != null) {
        await File('${device.path}/gpu_busy_percent').writeAsString(busy);
      }
    }

    test('detects only cards exposing gpu_busy_percent', () async {
      await card('card2', busy: '14\n', vendor: '0x1002');
      await card('card1', vendor: '0x10de'); // NVIDIA: no sysfs busy metric.
      await Directory('${root.path}/card2-DP-4').create(); // Connector.
      await Directory('${root.path}/renderD128').create();

      final service = GpuUsageService(
        drmRoot: root.path,
        nvml: _FakeNvml(const []),
      );
      final samples = await service.read();

      expect(samples, hasLength(1));
      expect(samples.single.id, 'card2');
      expect(samples.single.label, 'AMD');
      expect(samples.single.usage, 0.14);
    });

    test('merges sysfs GPUs with NVML GPUs', () async {
      await card('card2', busy: '20\n', vendor: '0x1002');

      final service = GpuUsageService(
        drmRoot: root.path,
        nvml: _FakeNvml(const [
          GpuSample(id: 'nvml0', label: 'NV', usage: 0.8),
        ]),
      );
      final samples = await service.read();

      expect(samples.map((s) => s.id), ['card2', 'nvml0']);
      expect(samples.map((s) => s.label), ['AMD', 'NV']);
    });

    test('reads the preferred GPU hwmon sensor with utilization', () async {
      await card('card2', busy: '42\n', vendor: '0x1002');
      final hwmon = Directory('${root.path}/card2/device/hwmon/hwmon6');
      await hwmon.create(recursive: true);
      await File('${hwmon.path}/temp1_label').writeAsString('junction\n');
      await File('${hwmon.path}/temp1_input').writeAsString('79000\n');
      await File('${hwmon.path}/temp2_label').writeAsString('edge\n');
      await File('${hwmon.path}/temp2_input').writeAsString('62500\n');

      final service = GpuUsageService(
        drmRoot: root.path,
        nvml: _FakeNvml(const []),
      );
      final sample = (await service.read()).single;

      expect(sample.usage, 0.42);
      expect(sample.temperatureC, 62.5);
    });

    test('a transiently unreadable counter drops that reading only', () async {
      await card('card0', busy: 'garbage', vendor: '0x8086');
      await card('card1', busy: '55\n', vendor: '0x1002');

      final service = GpuUsageService(
        drmRoot: root.path,
        nvml: _FakeNvml(const []),
      );
      final samples = await service.read();

      expect(samples.map((s) => s.id), ['card1']);
    });

    test('a missing drm root yields no GPUs', () async {
      final service = GpuUsageService(
        drmRoot: '${root.path}/nowhere',
        nvml: _FakeNvml(const []),
      );

      expect(await service.read(), isEmpty);
    });
  });
}

class _FakeNvml extends NvmlReader {
  _FakeNvml(this._samples);

  final List<GpuSample> _samples;

  @override
  List<GpuSample> read() => _samples;
}
