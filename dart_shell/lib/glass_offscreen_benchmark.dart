import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/theme/glass_configuration.dart';
import 'src/theme/shell_theme.dart';
import 'src/widgets/retained_translation.dart';
import 'src/widgets/shell_backdrop_blur.dart';

/// A separate AOT entry point for Denial's render-node-only profiling worker.
/// It has no shell controller, platform services, input or visible window.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['DENIAL_OFFSCREEN_BENCHMARK_OUTPUT'];
  final settings = Platform.environment['DENIAL_OFFSCREEN_BENCHMARK_SETTINGS'];
  if (output == null || settings == null) {
    throw StateError('Start this bundle through denial-glass-benchmark');
  }
  final json = jsonDecode(await File(settings).readAsString()) as Map;
  final appearance = json['appearance'] as Map;
  if (appearance['transparencyMode'] != 'glass') {
    throw StateError('The supplied settings must already have glass enabled');
  }
  final theme = ShellThemeData(
    transparencyMode: ShellTransparencyMode.glass,
    glass: ShellGlassConfiguration.fromJson(appearance['glass']),
    panelOpacity: (appearance['panelOpacity'] as num).toDouble(),
    cardOpacity: (appearance['cardOpacity'] as num).toDouble(),
    cornerRadiusScale: (appearance['cornerRadiusScale'] as num).toDouble(),
  );
  await File(output).create(exclusive: true);
  final timeline = await _TimelineCapture.start(output);
  runApp(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ShellTheme(
          data: theme,
          child: Builder(
            builder: (context) => MediaQuery.fromView(
              view: View.of(context),
              child: _Workload(output: output, timeline: timeline),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Optional CPU tracing through this worker's own VM service. The service URI
/// stays in memory; neither the authenticated address nor errors containing it
/// are written to logs or benchmark results.
class _TimelineCapture {
  _TimelineCapture(this.output);

  final String output;
  final metadata = <String, Object?>{'status': 'disabled'};
  Uri? _uri;

  static Future<_TimelineCapture> start(String output) async {
    final capture = _TimelineCapture(output);
    if (Platform.environment['DENIAL_OFFSCREEN_BENCHMARK_TIMELINE'] != '1') {
      return capture;
    }
    try {
      capture.metadata['step'] = 'service';
      Uri? uri;
      for (var attempt = 0; attempt < 20; attempt++) {
        final service = await developer.Service.getInfo().timeout(
          const Duration(seconds: 2),
        );
        uri = service.serverUri;
        if (uri != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (uri == null || uri.scheme != 'http' || uri.host != '127.0.0.1') {
        throw StateError('Worker VM service unavailable');
      }
      capture._uri = uri;
      capture.metadata['step'] = 'flags';
      await capture._call('setVMTimelineFlags', {
        // HTTP parameters use the VM service's enum-list syntax, whose
        // elements are unquoted (unlike the WebSocket JSON-RPC list).
        'recordedStreams': '[Dart,Embedder,GC]',
      });
      capture.metadata['step'] = 'clear';
      await capture._call('clearVMTimeline');
      capture.metadata['status'] = 'recording';
      capture.metadata.remove('step');
    } catch (error) {
      capture.metadata.addAll({
        'status': 'unavailable',
        'error_type': error.runtimeType.toString(),
      });
    }
    return capture;
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, String>? parameters,
  ]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      return await (() async {
        final request = await client.getUrl(
          _uri!.resolve(method).replace(queryParameters: parameters),
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw StateError('Worker VM request failed');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 64 * 1024 * 1024) {
            throw StateError('Worker timeline exceeded its size limit');
          }
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (body.containsKey('error')) {
          metadata['rpc_error_code'] = (body['error'] as Map)['code'];
          throw StateError('Worker VM returned an RPC error');
        }
        return body['result'] as Map<String, dynamic>;
      })().timeout(const Duration(seconds: 5));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> finish() async {
    if (metadata['status'] != 'recording') return;
    try {
      // The workload has stopped before serializing any trace events.
      final result = await _call('getVMTimeline');
      final file = File('$output.timeline.json');
      await file.create(exclusive: true);
      await file.writeAsString(jsonEncode(result), flush: true);
      metadata.addAll({
        'status': 'captured',
        'events': (result['traceEvents'] as List?)?.length ?? 0,
      });
    } catch (error) {
      metadata.addAll({
        'status': 'failed',
        'error_type': error.runtimeType.toString(),
      });
    }
  }
}

class _Workload extends StatefulWidget {
  const _Workload({required this.output, required this.timeline});
  final String output;
  final _TimelineCapture timeline;

  @override
  State<_Workload> createState() => _WorkloadState();
}

class _WorkloadState extends State<_Workload>
    with SingleTickerProviderStateMixin {
  static const _phases = [
    'stationary',
    'moving_direct',
    'moving_backdrop',
    'moving_nested',
    'glass_removed',
  ];
  static const _phaseUs = 15000000;
  static const _warmupUs = 3000000;
  // Observe removal immediately, including deferred cache retirement.
  static int _phaseWarmupUs(int phase) => phase == 4 ? 0 : _warmupUs;
  late final Ticker _ticker = createTicker(_tick);
  final _panel = ValueNotifier(Offset.zero);
  final _backdrop = ValueNotifier(Offset.zero);
  final _marker = ValueNotifier(Offset.zero);
  final _timings = <FrameTiming>[];
  final _starts = <int?>[for (final _ in _phases) null];
  final _ends = <int?>[for (final _ in _phases) null];
  final _ticks = <List<int>>[for (final _ in _phases) <int>[]];
  Timer? _start;
  Timer? _drain;
  int? _requestedStartPhaseUs;
  int? _scheduledStartUs;
  int? _actualStartUs;
  var _phase = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_record);
    final startPhase =
        Platform.environment['DENIAL_OFFSCREEN_BENCHMARK_START_PHASE_US'];
    if (startPhase != null) {
      final parsed = int.tryParse(startPhase);
      if (parsed == null || parsed < 0 || parsed >= 1000000) {
        throw StateError('Benchmark start phase must be in [0, 1000000) us');
      }
      _requestedStartPhaseUs = parsed;
    }
    // Mesa's BO cache ages allocations in whole CLOCK_MONOTONIC seconds.
    // Control this phase so its cleanup clock cannot confound A/B runs of our
    // two-second animation. Record the first vsync as well: Timer and vsync
    // scheduling can place it slightly after the requested instant.
    final now = developer.Timeline.now;
    var scheduled = now + 3000000;
    if (_requestedStartPhaseUs case final phase?) {
      scheduled += (phase - scheduled % 1000000) % 1000000;
    }
    _scheduledStartUs = scheduled;
    _start = Timer(Duration(microseconds: scheduled - now), _ticker.start);
  }

  void _record(List<FrameTiming> timings) {
    if (_timings.length < 20000) _timings.addAll(timings);
  }

  void _tick(Duration elapsed) {
    final us = elapsed.inMicroseconds;
    final now =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    _actualStartUs ??= now;
    final phase = us ~/ _phaseUs;
    if (phase >= _phases.length) {
      _ends[_phase] = now;
      _ticker.stop();
      _drain = Timer(
        const Duration(milliseconds: 1500),
        () => unawaited(_finish()),
      );
      return;
    }
    if (_phase != phase) {
      _ends[_phase] = now;
      setState(() => _phase = phase);
    }
    if (us % _phaseUs >= _phaseWarmupUs(phase)) {
      _starts[phase] ??= now;
      _ticks[phase].add(now);
    }
    final wave = math.sin(us / 1000000 * math.pi);
    _panel.value = Offset(
      0,
      phase == 1 || phase == 3 ? -580 * (0.45 - 0.4 * wave) : 0,
    );
    _backdrop.value = Offset(200 * (1 + wave), 0);
    _marker.value = Offset(20 * wave, 0);
  }

  Future<void> _finish() async {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    final media = MediaQuery.of(context);
    final theme = ShellTheme.of(context);
    await widget.timeline.finish();
    await File(widget.output).writeAsString(
      jsonEncode({
        'version': 6,
        'mode': 'offscreen_profile',
        'status': 'completed',
        'pid': pid,
        'logical_width': media.size.width,
        'logical_height': media.size.height,
        'device_pixel_ratio': media.devicePixelRatio,
        'glass': theme.glass.toJson(),
        'panel_opacity': theme.panelOpacity,
        'timeline': widget.timeline.metadata,
        'requested_start_phase_us': _requestedStartPhaseUs,
        'scheduled_start_us': _scheduledStartUs,
        'actual_start_us': _actualStartUs,
        'default_warmup_us': _warmupUs,
        'default_measurement_us': _phaseUs - _warmupUs,
        'phases': [for (var i = 0; i < _phases.length; i++) _phaseResult(i)],
      }),
      flush: true,
    );
  }

  Map<String, Object?> _phaseResult(int i) {
    final start = _starts[i];
    final end = _ends[i];
    final frames = _timings.where((frame) {
      final vsync = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      return start != null && end != null && vsync >= start && vsync < end;
    }).toList();
    final ticks = _ticks[i];
    return {
      'phase': _phases[i],
      'warmup_us': _phaseWarmupUs(i),
      'measurement_us': _phaseUs - _phaseWarmupUs(i),
      'start_us': start,
      'end_us': end,
      'timed_frames': frames.length,
      'vsync_start_us': [
        for (final f in frames)
          f.timestampInMicroseconds(FramePhase.vsyncStart),
      ],
      'raster_start_us': [
        for (final f in frames)
          f.timestampInMicroseconds(FramePhase.rasterStart),
      ],
      'build_us': [for (final f in frames) f.buildDuration.inMicroseconds],
      'raster_us': [for (final f in frames) f.rasterDuration.inMicroseconds],
      'total_us': [for (final f in frames) f.totalSpan.inMicroseconds],
      'tick_intervals_us': [
        for (var t = 1; t < ticks.length; t++) ticks[t] - ticks[t - 1],
      ],
    };
  }

  @override
  void dispose() {
    _start?.cancel();
    _drain?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_record);
    _ticker.dispose();
    _panel.dispose();
    _backdrop.dispose();
    _marker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff3868a1), Color(0xff754238), Color(0xff102940)],
            ),
          ),
        ),
        if (_phase == 2)
          Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              child: RetainedTranslation(
                translation: _backdrop,
                child: const SizedBox(
                  width: 220,
                  height: 834,
                  child: ColoredBox(color: Color(0xff467ba8)),
                ),
              ),
            ),
          ),
        if (_phase != 4)
          Align(
            alignment: Alignment.topCenter,
            child: RetainedTranslation(
              translation: _panel,
              child: RepaintBoundary(
                child: SizedBox(
                  height: 580,
                  width: double.infinity,
                  child: ShellBackdropBlur(
                    separateChild: _phase != 3,
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(theme.panelRadius),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: theme.panelGradient(
                          theme.colors.panelBackground,
                          theme.colors.panelBackgroundBottom,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '04:00',
                              style: TextStyle(
                                fontSize: 64,
                                color: Color(0xffeeeeee),
                              ),
                            ),
                            const SizedBox(height: 24),
                            for (var row = 0; row < 4; row++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: Row(
                                  children: [
                                    for (var column = 0; column < 3; column++)
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Container(
                                            height: 68,
                                            decoration: BoxDecoration(
                                              color: Color(
                                                row.isEven
                                                    ? 0xa0586792
                                                    : 0xa0364356,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(22),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // Keep repainting after glass removal so deferred target retirement
        // is measured during real raster work. Glass motion already drives
        // the middle phases; a distant marker would inflate their damage.
        if (_phase == 0 || _phase == 4)
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
    );
  }
}
