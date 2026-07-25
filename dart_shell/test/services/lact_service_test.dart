import 'dart:convert';
import 'dart:io';

import 'package:denial_dart_shell/src/services/lact_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const amdId = '1002:7550-1DA2:E491-0000:0a:00.0';
  const nvidiaId = '10DE:2D04-1569:F328-0000:04:00.0';

  test('uses LACT newline-delimited JSON over a Unix socket', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-lact-test-',
    );
    final socketPath = '${directory.path}/lactd.sock';
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final requests = <Map<String, Object?>>[];
    final handlers = <Future<void>>[];

    Future<void> handle(Socket socket) async {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final request = Map<String, Object?>.from(jsonDecode(line) as Map);
      requests.add(request);
      final data = switch (request['command']) {
        'list_devices' => const <Object?>[
          <String, Object?>{'id': amdId, 'name': 'AMD GPU'},
        ],
        'get_gpu_config' => const <String, Object?>{
          'performance_level': 'auto',
        },
        _ => throw StateError('unexpected request'),
      };
      socket.add(
        utf8.encode(
          '${jsonEncode(<String, Object?>{'status': 'ok', 'data': data})}\n',
        ),
      );
      await socket.flush();
      await socket.close();
    }

    final subscription = server.listen((socket) {
      handlers.add(handle(socket));
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close();
      await Future.wait(handlers);
      await directory.delete(recursive: true);
    });

    final snapshot = await LactService(
      socketPath: socketPath,
    ).readAmdPerformancePreset();

    expect(snapshot.available, isTrue);
    expect(snapshot.preset, LactPerformancePreset.automatic);
    expect(requests.map((request) => request['command']), <Object?>[
      'list_devices',
      'get_gpu_config',
    ]);
  });

  test('reads the LACT performance preset from the AMD GPU only', () async {
    final requests = <Map<String, Object?>>[];
    final service = LactService(
      requestSender: (request) async {
        requests.add(request);
        return switch (request['command']) {
          'list_devices' => const <Object?>[
            <String, Object?>{'id': nvidiaId, 'name': 'NVIDIA GPU'},
            <String, Object?>{'id': amdId, 'name': 'AMD GPU'},
          ],
          'get_gpu_config' => const <String, Object?>{
            'performance_level': 'low',
          },
          _ => throw StateError('unexpected request'),
        };
      },
    );

    final snapshot = await service.readAmdPerformancePreset();

    expect(snapshot.available, isTrue);
    expect(snapshot.preset, LactPerformancePreset.low);
    expect(requests, hasLength(2));
    expect((requests.last['args'] as Map<Object?, Object?>)['id'], amdId);
  });

  test('changes only performance_level and confirms the LACT config', () async {
    const originalConfig = <String, Object?>{
      'fan_control_enabled': false,
      'power_cap': 290.0,
      'performance_level': 'low',
      'max_memory_clock': 875,
      'gpu_clock_offsets': <String, Object?>{'0': -202},
      'voltage_offset': -60,
    };
    final requests = <Map<String, Object?>>[];
    final service = LactService(
      requestSender: (request) async {
        requests.add(request);
        return switch (request['command']) {
          'list_devices' => const <Object?>[
            <String, Object?>{'id': amdId, 'name': 'AMD GPU'},
          ],
          'get_gpu_config' => originalConfig,
          'set_gpu_config' => 5,
          'confirm_pending_config' => null,
          _ => throw StateError('unexpected request'),
        };
      },
    );

    await service.applyAmdPerformancePreset(LactPerformancePreset.high);

    expect(requests.map((request) => request['command']), <Object?>[
      'list_devices',
      'get_gpu_config',
      'set_gpu_config',
      'confirm_pending_config',
    ]);
    final setArgs = requests[2]['args'] as Map<Object?, Object?>;
    expect(setArgs['id'], amdId);
    expect(setArgs['config'], <String, Object?>{
      ...originalConfig,
      'performance_level': LactPerformancePreset.high,
    });
    expect(requests.last['args'], <String, Object?>{'command': 'confirm'});
    expect(originalConfig['performance_level'], LactPerformancePreset.low);
  });

  test(
    'reports LACT as unavailable when its socket cannot be reached',
    () async {
      final service = LactService(
        requestSender: (_) async => throw const SocketException('missing'),
      );

      final snapshot = await service.readAmdPerformancePreset();

      expect(snapshot.available, isFalse);
      expect(snapshot.preset, isNull);
    },
  );

  test('rejects values outside LACT low, auto, and high presets', () {
    final service = LactService(requestSender: (_) async => null);

    expect(
      () => service.applyAmdPerformancePreset('manual'),
      throwsArgumentError,
    );
  });
}
