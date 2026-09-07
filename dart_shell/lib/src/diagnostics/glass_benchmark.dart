import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';
import '../widgets/retained_translation.dart';
import '../widgets/shade/quick_settings_panel.dart';

/// Opt-in, finite lab workload driven by Denial's own frame clock.
///
/// Set DENIAL_GLASS_BENCHMARK_OUTPUT to an unused JSON file in a private
/// directory. The real shade is exercised without changing shell settings or
/// sending input to applications. Normal sessions allocate no ticker or timer.
class GlassBenchmarkLayer extends StatelessWidget {
  const GlassBenchmarkLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final output = Platform.environment['DENIAL_GLASS_BENCHMARK_OUTPUT'];
    return output == null || output.isEmpty
        ? const SizedBox.shrink()
        : _GlassBenchmark(output: output);
  }
}

class _GlassBenchmark extends StatefulWidget {
  const _GlassBenchmark({required this.output});

  final String output;

  @override
  State<_GlassBenchmark> createState() => _GlassBenchmarkState();
}

class _GlassBenchmarkState extends State<_GlassBenchmark>
    with TickerProviderStateMixin {
  static const _phases = ['hidden', 'stationary', 'moving', 'moving_backdrop'];
  static const _warmupUs = 3000000;
  static const _measureUs = 12000000;
  static const _phaseUs = _warmupUs + _measureUs;

  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _progress = AnimationController(vsync: this);
  final _marker = ValueNotifier(Offset.zero);
  final _backdrop = ValueNotifier(Offset.zero);
  final _timings = <FrameTiming>[];
  final _ticks = <List<int>>[for (final _ in _phases) <int>[]];
  final _starts = <int?>[for (final _ in _phases) null];
  final _ends = <int?>[for (final _ in _phases) null];
  final _metadata = <String, Object?>{};
  Timer? _delay;
  Timer? _watchdog;
  Timer? _drain;
  ServerSocket? _server;
  final _clients = <Socket>{};
  String? _currentOutput;
  bool _preparing = false;
  int _phase = -1;
  bool _ownedOutput = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final file = File(widget.output);
      final parent = await file.parent.stat();
      if (!widget.output.startsWith('/') ||
          parent.type != FileSystemEntityType.directory ||
          (parent.mode & 0x3f) != 0) {
        throw ArgumentError('Benchmark output needs a private directory');
      }
      final socketPath = '${widget.output}.sock';
      final type = await FileSystemEntity.type(socketPath, followLinks: false);
      if (type == FileSystemEntityType.unixDomainSock) {
        Socket? existing;
        try {
          existing = await Socket.connect(
            InternetAddress(socketPath, type: InternetAddressType.unix),
            0,
            timeout: const Duration(milliseconds: 250),
          );
        } on SocketException {
          await File(socketPath).delete();
        }
        if (existing != null) {
          existing.destroy();
          throw StateError('Benchmark socket is already in use');
        }
      } else if (type != FileSystemEntityType.notFound) {
        throw StateError('Refusing to replace a non-socket benchmark path');
      }
      _server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      _server!.listen(_accept);
      if (!mounted) {
        await _server!.close();
        await File(socketPath).delete();
        return;
      }
      // Replacing only Flutter can reuse this endpoint without rerunning an
      // already completed measurement or restarting the compositor session.
      if (!await file.exists()) {
        await _requestRun(widget.output, const Duration(seconds: 10));
      }
      debugPrint('Denial glass benchmark listening $socketPath');
    } catch (error) {
      debugPrint('Denial glass benchmark unavailable: $error');
    }
  }

  bool get _running => _preparing || _delay?.isActive == true || _phase >= 0;

  void _accept(Socket client) {
    if (_clients.length >= 4) {
      client.destroy();
      return;
    }
    _clients.add(client);
    final bytes = <int>[];
    var requested = false;
    final timeout = Timer(const Duration(seconds: 3), client.destroy);
    client.listen(
      (packet) async {
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
            case 'status':
              client.writeln(
                jsonEncode({
                  'running': _running,
                  'pid': pid,
                  'output': _currentOutput,
                }),
              );
            case 'run':
              final name = request['name'] ?? 'glass';
              if (name is! String ||
                  !RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(name)) {
                throw ArgumentError('Invalid measurement name');
              }
              final output =
                  '${File(widget.output).parent.path}/'
                  '$name-${DateTime.now().microsecondsSinceEpoch}.json';
              await _requestRun(output, const Duration(seconds: 1));
              client.writeln(jsonEncode({'accepted': true, 'output': output}));
            case 'cancel':
              if (_preparing) throw StateError('Measurement is preparing');
              final wasRunning = _running;
              _delay?.cancel();
              if (wasRunning) _finish('cancelled');
              client.writeln(jsonEncode({'cancelled': true}));
            default:
              throw const FormatException('Expected run, status or cancel');
          }
        } catch (error) {
          client.writeln(jsonEncode({'error': '$error'}));
        }
        await client.close();
      },
      onError: (Object error) {
        timeout.cancel();
        _clients.remove(client);
        client.destroy();
      },
      onDone: () {
        timeout.cancel();
        _clients.remove(client);
        client.destroy();
      },
    );
  }

  Future<void> _requestRun(String output, Duration delay) async {
    if (_running) throw StateError('A measurement is already running');
    _preparing = true;
    try {
      await File(output).create(exclusive: true);
      if (!mounted) return;
      _currentOutput = output;
      _ownedOutput = true;
      _finishing = false;
      _metadata.clear();
      _timings.clear();
      for (var i = 0; i < _phases.length; i++) {
        _ticks[i].clear();
        _starts[i] = null;
        _ends[i] = null;
      }
      _delay = Timer(delay, _start);
    } finally {
      _preparing = false;
    }
  }

  void _start() {
    final theme = ShellTheme.of(context);
    final media = MediaQuery.of(context);
    _metadata.addAll({
      'version': 2,
      'pid': pid,
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'logical_width': media.size.width,
      'logical_height': media.size.height,
      'device_pixel_ratio': media.devicePixelRatio,
      'transparency_mode': theme.transparencyMode.name,
      'glass': theme.glass.toJson(),
      'panel_opacity': theme.effectivePanelOpacity,
      'warmup_us': _warmupUs,
      'measurement_us': _measureUs,
    });
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    _watchdog = Timer(const Duration(seconds: 90), () => _finish('stalled'));
    debugPrint('Denial glass benchmark started ${jsonEncode(_metadata)}');
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final elapsedUs = elapsed.inMicroseconds;
    final now =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    final next = elapsedUs ~/ _phaseUs;
    if (next >= _phases.length) {
      if (_phase >= 0) _ends[_phase] = now;
      _ticker.stop();
      _watchdog?.cancel();
      // Release engines batch timing callbacks. Keep the last phase in place
      // while draining so teardown frames do not enter its measured interval.
      _drain = Timer(
        const Duration(milliseconds: 1500),
        () => _finish('completed'),
      );
      return;
    }
    if (_phase != next) {
      if (_phase >= 0) _ends[_phase] = now;
      setState(() => _phase = next);
      debugPrint('Denial glass benchmark phase=${_phases[next]} vsync_us=$now');
    }
    final phaseTime = elapsedUs % _phaseUs;
    if (phaseTime >= _warmupUs) {
      _starts[next] ??= now;
      _ticks[next].add(now);
    }
    if (_timings.length >= 20000) {
      _finish('sample_limit');
      return;
    }
    final wave = math.sin(elapsedUs / 1000000 * math.pi);
    _progress.value = next == 2 ? 0.55 + 0.4 * wave : 1;
    final size = MediaQuery.sizeOf(context);
    _backdrop.value = Offset(size.width * 0.32 * (1 + wave), 0);
    // A small foreground repaint keeps stationary/hidden phases rendering
    // without invalidating the pixels behind the panel.
    _marker.value = Offset(20 * wave, 0);
  }

  void _recordTimings(List<FrameTiming> timings) {
    if (_timings.length < 20000) _timings.addAll(timings);
  }

  void _finish(String status) {
    if (_finishing) return;
    _finishing = true;
    _ticker.stop();
    _watchdog?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
    final results = <Map<String, Object?>>[];
    for (var i = 0; i < _phases.length; i++) {
      final start = _starts[i];
      final end = _ends[i];
      final frames = _timings.where((frame) {
        final vsync = frame.timestampInMicroseconds(FramePhase.vsyncStart);
        return start != null && end != null && vsync >= start && vsync < end;
      }).toList();
      final ticks = _ticks[i];
      results.add({
        'phase': _phases[i],
        'start_us': start,
        'end_us': end,
        'ticks': ticks.length,
        'timed_frames': frames.length,
        'build_us': [for (final f in frames) f.buildDuration.inMicroseconds],
        'raster_us': [for (final f in frames) f.rasterDuration.inMicroseconds],
        'total_us': [for (final f in frames) f.totalSpan.inMicroseconds],
        'tick_intervals_us': [
          for (var t = 1; t < ticks.length; t++) ticks[t] - ticks[t - 1],
        ],
      });
    }
    if (mounted) setState(() => _phase = -1);
    if (_ownedOutput) {
      unawaited(
        File(_currentOutput!)
            .writeAsString(
              jsonEncode({..._metadata, 'status': status, 'phases': results}),
              flush: true,
            )
            .then((_) => debugPrint('Denial glass benchmark $status'))
            .catchError((Object error) {
              debugPrint('Denial glass benchmark write failed: $error');
            }),
      );
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _watchdog?.cancel();
    _drain?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
    _ticker.dispose();
    _progress.dispose();
    _marker.dispose();
    _backdrop.dispose();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    final server = _server;
    if (server != null) {
      unawaited(
        server.close().then((_) async {
          final socket = File('${widget.output}.sock');
          if (await FileSystemEntity.type(socket.path, followLinks: false) ==
              FileSystemEntityType.unixDomainSock) {
            await socket.delete();
          }
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_phase < 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_phase == 3)
              Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  child: RetainedTranslation(
                    translation: _backdrop,
                    child: SizedBox(
                      width: MediaQuery.sizeOf(context).width * 0.35,
                      height: MediaQuery.sizeOf(context).height * 0.6,
                      child: const ColoredBox(color: Color(0xff467ba8)),
                    ),
                  ),
                ),
              ),
            if (_phase != 0)
              QuickSettingsShade(progress: _progress, active: false),
            if (_phase <= 1)
              Align(
                alignment: Alignment.bottomCenter,
                child: RepaintBoundary(
                  child: RetainedTranslation(
                    translation: _marker,
                    child: const SizedBox(
                      width: 8,
                      height: 8,
                      child: ColoredBox(color: Color(0xffffffff)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
