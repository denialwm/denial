import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/services/cpu_usage_service.dart';
import 'package:denial_dart_shell/src/services/gpu_usage_service.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';

void main() {
  group('LoadSeries', () {
    test('append mirrors the newest reading and caps the history', () {
      var load = LoadSeries.empty;
      for (var i = 0; i < LoadSeries.capacity + 5; i += 1) {
        load = load.append(
          i / 100,
          temperatureC: i == 3 ? 52.5 : null,
        );
      }

      expect(load.history, hasLength(LoadSeries.capacity));
      expect(load.current, (LoadSeries.capacity + 4) / 100);
      expect(load.history.last, load.current);
      // The oldest readings fell off the front.
      expect(load.history.first, 5 / 100);
      expect(load.temperatureC, 52.5);
      expect(() => load.history.add(0.0), throwsUnsupportedError);
    });
  });

  group('CpuUsageController', () {
    test('appends only usable deltas between samples', () {
      fakeAsync((async) {
        final controller = CpuUsageController(
          _ScriptedCpuService(const [
            CpuSample(
              busy: 100,
              total: 200,
              temperatureC: 48,
            ), // first sample: no delta yet
            CpuSample(
              busy: 150,
              total: 300,
              temperatureC: 52,
            ), // 50/100 -> 0.5
            null, // unreadable /proc/stat: nothing appended
            CpuSample(busy: 150, total: 300), // counters stalled: no delta
            CpuSample(busy: 250, total: 500), // 100/200 -> 0.5
          ]),
        );
        async.elapse(const Duration(seconds: 9));

        expect(controller.state.current, 0.5);
        expect(controller.state.history, const [0.5, 0.5]);
        expect(controller.state.temperatureC, 52);
        controller.dispose();
      });
    });
  });

  group('GpuUsageController', () {
    test('keeps one series per GPU and drops vanished GPUs', () {
      fakeAsync((async) {
        final controller = GpuUsageController(
          _ScriptedGpuService(const [
            [
              GpuSample(
                id: 'card2',
                label: 'AMD',
                usage: 0.2,
                temperatureC: 61,
              ),
              GpuSample(id: 'nvml0', label: 'NV', usage: 0.8),
            ],
            [
              GpuSample(
                id: 'card2',
                label: 'AMD',
                usage: 0.4,
                temperatureC: 63,
              ),
              GpuSample(id: 'nvml0', label: 'NV', usage: 0.6),
            ],
            [
              GpuSample(id: 'card2', label: 'AMD', usage: 0.6),
            ],
          ]),
        );
        async.elapse(const Duration(seconds: 3));

        expect(controller.state, hasLength(2));
        expect(controller.state[0].label, 'AMD');
        expect(controller.state[0].series.history, const [0.2, 0.4]);
        expect(controller.state[0].series.temperatureC, 63);
        expect(controller.state[1].label, 'NV');
        expect(controller.state[1].series.history, const [0.8, 0.6]);

        async.elapse(const Duration(seconds: 2));
        expect(controller.state, hasLength(1));
        expect(controller.state[0].series.history, const [0.2, 0.4, 0.6]);
        expect(controller.state[0].series.temperatureC, 63);
        controller.dispose();
      });
    });
  });
}

class _ScriptedGpuService extends GpuUsageService {
  _ScriptedGpuService(this._readings);

  final List<List<GpuSample>> _readings;
  int _next = 0;

  @override
  Future<List<GpuSample>> read() async {
    if (_next >= _readings.length) {
      return _readings.last;
    }
    return _readings[_next++];
  }
}

class _ScriptedCpuService extends CpuUsageService {
  _ScriptedCpuService(this._samples);

  final List<CpuSample?> _samples;
  int _next = 0;

  @override
  Future<CpuSample?> read() async {
    if (_next >= _samples.length) {
      return _samples.last;
    }
    return _samples[_next++];
  }
}
