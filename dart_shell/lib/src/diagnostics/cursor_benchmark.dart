import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming, Offset;

import 'package:flutter/scheduler.dart';

import '../models/display_layout.dart';

/// Explicitly enabled lab instrumentation, never an application input source.
/// Commands use a private Unix socket and move the existing shell cursor only.
class CursorBenchmark {
  CursorBenchmark({
    required TickerProvider vsync,
    required this.layout,
    required this.move,
    required this.restore,
    required this.available,
  }) {
    _ticker = vsync.createTicker(_tick);
  }

  final DisplayLayout? Function() layout;
  final void Function(Offset) move;
  final void Function() restore;
  final bool Function() available;
  late final Ticker _ticker;
  ServerSocket? _server;
  String? _path;
  final Set<Socket> _clients = {};
  Socket? _runClient;
  CursorCircle? _circle;
  final List<FrameTiming> _timings = [];
  final List<int> _tickTimes = [];
  int? _measureStart;
  int? _measureEnd;
  Timer? _drain;
  Timer? _watchdog;
  bool _disposed = false;
  bool get running => _circle != null;

  Future<void> listen(String path) async {
    final parent = await Directory(path).parent.stat();
    if (!path.startsWith('/') ||
        parent.type != FileSystemEntityType.directory ||
        (parent.mode & 0x3f) != 0) {
      throw ArgumentError(
        'Benchmark socket needs a private existing directory',
      );
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.unixDomainSock) {
      Socket? existing;
      try {
        existing = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
          timeout: const Duration(milliseconds: 250),
        );
      } on SocketException {
        await File(path).delete();
      }
      if (existing != null) {
        existing.destroy();
        throw StateError('Benchmark socket is already in use');
      }
    } else if (type != FileSystemEntityType.notFound) {
      throw StateError('Refusing to replace a non-socket benchmark path');
    }
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    if (_disposed) {
      await server.close();
      await File(path).delete();
      return;
    }
    _server = server;
    _path = path;
    server.listen(_accept);
  }

  void _accept(Socket client) {
    if (_clients.length >= 4) {
      client.destroy();
      return;
    }
    _clients.add(client);
    final bytes = <int>[];
    var requested = false;
    final timeout = Timer(const Duration(seconds: 3), () {
      if (!requested) client.destroy();
    });
    client.listen(
      (packet) {
        if (requested) return;
        bytes.addAll(packet);
        if (bytes.length > 4096) {
          client.destroy();
          return;
        }
        final end = bytes.indexOf(10);
        if (end < 0) return;
        requested = true;
        timeout.cancel();
        try {
          final request = jsonDecode(utf8.decode(bytes.sublist(0, end)));
          if (request is! Map<String, dynamic>) {
            throw const FormatException('Expected a JSON object');
          }
          switch (request['method']) {
            case 'run':
              _start(client, request);
            case 'status':
              _send(client, {
                'event': 'status',
                'version': 1,
                'pid': pid,
                'running': running,
                'available': available(),
                'outputs': [
                  for (final output in layout()?.outputs ?? <DisplayOutput>[])
                    _outputJson(output),
                ],
              });
              unawaited(client.close());
            case 'cancel':
              cancel('requested');
              _send(client, {'event': 'cancelled'});
              unawaited(client.close());
            default:
              throw const FormatException('Expected run, status or cancel');
          }
        } catch (error) {
          _send(client, {'event': 'error', 'message': '$error'});
          unawaited(client.close());
        }
      },
      onError: (Object error) {
        if (identical(client, _runClient)) cancel('client_disconnected');
        timeout.cancel();
        _clients.remove(client);
        client.destroy();
      },
      onDone: () {
        if (identical(client, _runClient)) cancel('client_disconnected');
        timeout.cancel();
        _clients.remove(client);
        client.destroy();
      },
    );
  }

  void _start(Socket client, Map<String, dynamic> request) {
    if (running) throw StateError('A benchmark is already running');
    if (!available()) throw StateError('The shell cursor is unavailable');
    final currentLayout = layout();
    if (currentLayout == null || currentLayout.outputs.isEmpty) {
      throw StateError('No display layout');
    }
    final outputId = request['monitor_id'] ?? currentLayout.tickerMonitorId;
    final output = currentLayout.outputs.firstWhere(
      (output) => output.monitorId == outputId,
      orElse: () => throw ArgumentError('Unknown monitor_id'),
    );
    final circle = CursorCircle.fromJson(request, output);
    _timings.clear();
    _tickTimes.clear();
    _measureStart = null;
    _measureEnd = null;
    _runClient = client;
    _circle = circle;
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    _send(client, {
      'event': 'started',
      'version': 1,
      'pid': pid,
      'path': circle.toJson(),
      'output': _outputJson(output),
      'ticker_monitor_id': currentLayout.tickerMonitorId,
    });
    _watchdog = Timer(
      Duration(microseconds: circle.totalUs) + const Duration(seconds: 10),
      () => cancel('frame_clock_stalled'),
    );
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final circle = _circle;
    if (circle == null) return;
    final now =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    if (elapsed.inMicroseconds >= circle.totalUs) {
      _measureEnd = now;
      _ticker.stop();
      _send(_runClient!, {'event': 'measurement_end', 'vsync_us': now});
      // Release engines batch timing reports. Drain them outside CPU sampling.
      _drain = Timer(const Duration(milliseconds: 1500), _finish);
      return;
    }
    if (elapsed.inMicroseconds >= circle.warmupUs) {
      if (_measureStart == null) {
        _measureStart = now;
        _send(_runClient!, {'event': 'measurement_start', 'vsync_us': now});
      }
      if (_tickTimes.length >= 100000) {
        cancel('sample_limit');
        return;
      }
      _tickTimes.add(now);
    }
    move(circle.at(elapsed));
  }

  void _recordTimings(List<FrameTiming> timings) {
    final start = _measureStart;
    if (start == null) return;
    for (final timing in timings) {
      final vsync = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      if (vsync >= start && (_measureEnd == null || vsync < _measureEnd!)) {
        if (_timings.length >= 100000) {
          cancel('sample_limit');
          return;
        }
        _timings.add(timing);
      }
    }
  }

  void _finish() {
    final client = _runClient;
    final start = _measureStart;
    final end = _measureEnd;
    if (client == null || start == null || end == null) {
      cancel('no_measurement');
      return;
    }
    final timings = _timings
        .where(
          (timing) =>
              timing.timestampInMicroseconds(FramePhase.vsyncStart) < end,
        )
        .toList(growable: false);
    final result = <String, Object>{
      'event': 'completed',
      'duration_us': end - start,
      'cursor_ticks': _tickTimes.length,
      'timed_frames': timings.length,
      'build_us': [
        for (final timing in timings) timing.buildDuration.inMicroseconds,
      ],
      'raster_us': [
        for (final timing in timings) timing.rasterDuration.inMicroseconds,
      ],
      'total_span_us': [
        for (final timing in timings) timing.totalSpan.inMicroseconds,
      ],
      'tick_intervals_us': [
        for (var i = 1; i < _tickTimes.length; i++)
          _tickTimes[i] - _tickTimes[i - 1],
      ],
    };
    _clear();
    _send(client, result);
    unawaited(client.close());
  }

  void cancel(String reason) {
    if (!running) return;
    final client = _runClient;
    _clear();
    if (client != null) {
      _send(client, {'event': 'cancelled', 'reason': reason});
      unawaited(client.close());
    }
  }

  void _clear() {
    _ticker.stop();
    _watchdog?.cancel();
    _drain?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
    _circle = null;
    _runClient = null;
    restore();
    _timings.clear();
    _tickTimes.clear();
  }

  void dispose() {
    _disposed = true;
    cancel('disposed');
    _ticker.dispose();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    final server = _server;
    final path = _path;
    if (server != null) {
      unawaited(
        server.close().then((_) async {
          if (path != null && await File(path).exists()) {
            await File(path).delete();
          }
        }),
      );
    }
  }

  static void _send(Socket client, Map<String, Object?> message) {
    client.write('${jsonEncode(message)}\n');
  }

  static Map<String, Object> _outputJson(DisplayOutput output) => {
    'monitor_id': output.monitorId,
    'name': output.name,
    'x': output.logicalRect.left,
    'y': output.logicalRect.top,
    'width': output.logicalRect.width,
    'height': output.logicalRect.height,
    'scale': output.scale,
    'refresh_hz': output.refreshRate,
  };
}

/// Wall-time trajectory; missed frames never slow the requested movement down.
class CursorCircle {
  const CursorCircle({
    required this.center,
    required this.radius,
    required this.periodUs,
    required this.warmupUs,
    required this.durationUs,
  });

  factory CursorCircle.fromJson(
    Map<String, dynamic> json,
    DisplayOutput output,
  ) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key] ?? fallback;
      if (value is! num || !value.isFinite || value < min || value > max) {
        throw ArgumentError('$key must be between $min and $max');
      }
      return value.toDouble();
    }

    final bounds = output.logicalRect.deflate(32);
    final radius = number(
      'radius',
      math.min(180, bounds.shortestSide / 3),
      1,
      4096,
    );
    final center = Offset(
      number('center_x', bounds.center.dx, bounds.left, bounds.right),
      number('center_y', bounds.center.dy, bounds.top, bounds.bottom),
    );
    if (!bounds.contains(center - Offset(radius, radius)) ||
        !bounds.contains(center + Offset(radius, radius))) {
      throw ArgumentError('The entire circle must fit inside the output');
    }
    return CursorCircle(
      center: center,
      radius: radius,
      periodUs: (number('period_seconds', 2, 0.1, 30) * 1000000).round(),
      warmupUs: (number('warmup_seconds', 5, 0.1, 30) * 1000000).round(),
      durationUs: (number('duration_seconds', 30, 1, 120) * 1000000).round(),
    );
  }

  final Offset center;
  final double radius;
  final int periodUs;
  final int warmupUs;
  final int durationUs;
  int get totalUs => warmupUs + durationUs;

  Offset at(Duration elapsed) {
    final angle = 2 * math.pi * (elapsed.inMicroseconds % periodUs) / periodUs;
    return center + Offset(math.cos(angle), math.sin(angle)) * radius;
  }

  Map<String, Object> toJson() => {
    'center_x': center.dx,
    'center_y': center.dy,
    'radius': radius,
    'period_seconds': periodUs / 1000000,
    'warmup_seconds': warmupUs / 1000000,
    'duration_seconds': durationUs / 1000000,
  };
}
