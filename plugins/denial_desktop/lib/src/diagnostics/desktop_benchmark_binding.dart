import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/desktop_overview_target.dart';
import '../desktop/desktop_workspace.dart';

/// Lab automation only. A private runtime marker opts in before bundle load.
/// No timers, frame callbacks, or sockets are installed in ordinary sessions.
class DesktopBenchmarkBinding extends ConsumerStatefulWidget {
  const DesktopBenchmarkBinding({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DesktopBenchmarkBinding> createState() =>
      _DesktopBenchmarkBindingState();
}

class _DesktopBenchmarkBindingState
    extends ConsumerState<DesktopBenchmarkBinding> {
  ServerSocket? _server;
  String? _socketPath;
  final _clients = <Socket>{};
  final _frames = <FrameTiming>[];
  int? _start;
  int? _end;
  bool _overflow = false;
  bool _draining = false;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtime == null) return;
    final directory = '$runtime/denial';
    if (!File('$directory/benchmark.enabled').existsSync()) return;
    unawaited(_listen('$directory/benchmark.sock'));
  }

  Future<void> _listen(String path) async {
    try {
      final parent = await Directory(path).parent.stat();
      if ((parent.mode & 0x3f) != 0) {
        throw StateError('Benchmark requires a private runtime directory');
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.unixDomainSock) {
          throw StateError('Refusing to replace a non-socket');
        }
        Socket? prior;
        try {
          prior = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
            timeout: const Duration(milliseconds: 250),
          );
        } on SocketException {
          await File(path).delete();
        }
        if (prior != null) {
          prior.destroy();
          throw StateError('Benchmark socket is already listening');
        }
      }
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      if (!mounted) {
        await server.close();
        await File(path).delete();
        return;
      }
      _server = server;
      _socketPath = path;
      server.listen(_accept);
    } catch (error) {
      debugPrint('Denial benchmark unavailable: $error');
    }
  }

  void _accept(Socket client) {
    if (_clients.length >= 8) {
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
        if (bytes.length > 8192) {
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
            throw const FormatException('Expected JSON object');
          }
          final result = await _dispatch(request);
          client.writeln(jsonEncode({'ok': true, 'result': result}));
        } catch (error) {
          client.writeln(jsonEncode({'ok': false, 'error': '$error'}));
        } finally {
          await client.close();
        }
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

  Map<String, Object?> _snapshot() {
    final shell = ref.read(shellControllerProvider);
    final workspace = ref.read(desktopWorkspaceProvider);
    final settings = ref.read(shellSettingsProvider);
    return {
      'version': 1,
      'pid': pid,
      'clock_us': developer.Timeline.now,
      'locked': shell.locked,
      'recording': _start != null,
      'workspaces_enabled': workspace.workspacesEnabled,
      'workspace_count': workspace.workspaceCount,
      'window_layout': settings.layout.windowLayout.name,
      'overview': workspace.overviewActive,
      'active_workspaces': {
        for (final entry in workspace.activeWorkspaces.entries)
          '${entry.key}': entry.value,
      },
      'transitions': [
        for (final t in workspace.workspaceTransitions.values)
          {
            'monitor_id': t.monitorId,
            'from': t.fromWorkspace,
            'to': t.toWorkspace,
            'serial': t.serial,
            'retained_exits': t.retainedExits.length,
          },
      ],
      'windows': [
        for (final w in shell.openAppWindows)
          {
            'object_id': w.objectId,
            'window_id': w.windowId,
            'app_id': w.appId,
            'title': w.title,
            'monitor_id': w.monitorId,
            'workspace_id': w.workspaceId,
            'minimized': w.minimized,
          },
      ],
    };
  }

  Future<Object?> _dispatch(Map<String, dynamic> request) async {
    final method = request['method'];
    if (method == 'state') return _snapshot();
    // Read-only setup metadata, requested separately from the hot state RPC.
    if (method == 'surfaces') {
      return [
        for (final window in ref.read(shellControllerProvider).openAppWindows)
          {
            'object_id': window.objectId,
            'app_id': window.appId,
            'opacity': window.opacity,
            'opacity_class': window.opacityClass.name,
            'client_texture': window.clientTexture == null
                ? null
                : {
                    'texture_id': window.clientTexture!.textureId,
                    'width': window.clientTexture!.width,
                    'height': window.clientTexture!.height,
                    'source_width': window.clientTexture!.sourceWidth,
                    'source_height': window.clientTexture!.sourceHeight,
                  },
            'content': {
              'x': window.presentationCoordinateRect.left,
              'y': window.presentationCoordinateRect.top,
              'width': window.presentationCoordinateRect.width,
              'height': window.presentationCoordinateRect.height,
            },
            'layers': [
              for (final layer in window.paintedMainSurfaceLayers)
                {
                  'surface_id': layer.surfaceId,
                  'texture_id': layer.textureId,
                  'opaque': layer.opaque,
                  'opacity': layer.opacity,
                  'x': layer.surfaceX,
                  'y': layer.surfaceY,
                  'width': layer.surfaceWidth,
                  'height': layer.surfaceHeight,
                  'buffer_width': layer.width,
                  'buffer_height': layer.height,
                  'transform': layer.transform,
                },
            ],
          },
      ];
    }
    if (method == 'frames.cancel') {
      _cancelRecording();
      return null;
    }
    if (ref.read(shellControllerProvider).locked) {
      throw StateError('Session is locked');
    }
    final bridge = ref.read(denialBridgeProvider);
    final workspace = ref.read(desktopWorkspaceProvider);
    switch (method) {
      case 'windows.close_all':
        final windows = ref.read(shellControllerProvider).openAppWindows;
        for (final window in windows) {
          bridge.closeWindow(window);
        }
        return {'requested': windows.map((w) => w.objectId).toList()};
      case 'window.move':
        final window = ref
            .read(shellControllerProvider)
            .windowByObjectId(request['object_id'] as int);
        if (window == null || !window.isUserApp) {
          throw StateError('Unknown application window');
        }
        final monitor = request['monitor_id'] as int;
        final target = _workspace(request, monitor);
        bridge.moveWindowToWorkspace(
          window,
          monitorId: monitor,
          workspaceId: target,
          follow: false,
        );
        return {'accepted_us': developer.Timeline.now};
      case 'workspace.switch':
        final monitor = request['monitor_id'] as int;
        final target = _workspace(request, monitor);
        bridge.switchWorkspace(monitorId: monitor, workspaceId: target);
        return {'accepted_us': developer.Timeline.now};
      case 'overview.set':
        final open = request['open'] as bool;
        final controller = ref.read(desktopWorkspaceProvider.notifier);
        if (!open) {
          controller.closeOverview();
        } else if (!workspace.overviewActive) {
          final shell = ref.read(shellControllerProvider);
          final layout = ref.read(shellSettingsProvider).layout;
          final managed = layout.windowLayout != DesktopWindowLayout.stacking;
          final target = DesktopOverviewTarget.resolve(
            viewSize: workspace.viewSize,
            displayLayout: ref.read(displayLayoutProvider),
            windows: shell.openAppWindows,
            workspace: workspace,
            foregroundObjectId: shell.foregroundObjectId,
            preferredMonitorId: request['monitor_id'] as int,
            allWorkspaces: managed,
          );
          if (target == null) throw StateError('No overview target');
          controller.closePanels();
          if (managed) {
            controller.openWorkspaceOverview(
              monitorId: target.monitorId,
              bounds: target.bounds,
              backgroundBounds: target.backgroundBounds,
              viewport: target.workArea,
              orientation: layout.workspaceSwitchingOrientation,
              selectedObjectId: shell.foregroundObjectId,
            );
          } else {
            controller.toggleOverview(
              monitorId: target.monitorId,
              bounds: target.bounds,
              backgroundBounds: target.backgroundBounds,
              objectIds: target.objectIds,
              selectedObjectId: shell.foregroundObjectId,
            );
          }
        }
        return {'accepted_us': developer.Timeline.now, 'state': _snapshot()};
      case 'frames.begin':
        if (_start != null || _draining) {
          throw StateError('A frame capture is already running');
        }
        _frames.clear();
        _overflow = false;
        _end = null;
        _start = developer.Timeline.now;
        SchedulerBinding.instance.addTimingsCallback(_record);
        _watchdog = Timer(const Duration(minutes: 5), _cancelRecording);
        return {'start_us': _start};
      case 'frames.end':
        if (_start == null || _draining) {
          throw StateError('No frame capture or already draining');
        }
        _end = developer.Timeline.now;
        _draining = true;
        // Release engines batch FrameTiming delivery. Do not measure the drain.
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        if (!mounted || _start == null) throw StateError('Capture cancelled');
        final frames = _frames.where((f) {
          final t = f.timestampInMicroseconds(FramePhase.vsyncStart);
          return t >= _start! && t < _end!;
        });
        final result = {
          'start_us': _start,
          'end_us': _end,
          'overflow': _overflow,
          'frames': [
            for (final f in frames)
              [
                f.timestampInMicroseconds(FramePhase.vsyncStart),
                f.buildDuration.inMicroseconds,
                f.rasterDuration.inMicroseconds,
                f.totalSpan.inMicroseconds,
              ],
          ],
          'columns': ['vsync_us', 'build_us', 'raster_us', 'total_span_us'],
        };
        _cancelRecording();
        return result;
      default:
        throw ArgumentError('Unknown benchmark method: $method');
    }
  }

  int _workspace(Map<String, dynamic> request, int monitor) {
    final state = ref.read(desktopWorkspaceProvider);
    final target = request['workspace_id'] as int;
    if (!state.workspacesEnabled ||
        !state.activeWorkspaces.containsKey(monitor) ||
        target < 1 ||
        target > state.workspaceCount) {
      throw ArgumentError('Unknown monitor or disabled/invalid workspace');
    }
    return target;
  }

  void _record(List<FrameTiming> frames) {
    if (_frames.length + frames.length > 40000) {
      _overflow = true;
      return;
    }
    _frames.addAll(frames);
  }

  void _cancelRecording() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    _watchdog?.cancel();
    _watchdog = null;
    _start = null;
    _end = null;
    _frames.clear();
    _draining = false;
  }

  @override
  void dispose() {
    _cancelRecording();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    final server = _server;
    final path = _socketPath;
    if (server != null && path != null) {
      unawaited(server.close().then((_) async => File(path).delete()));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
