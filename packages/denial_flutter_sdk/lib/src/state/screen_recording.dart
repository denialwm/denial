import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../launcher/launcher_providers.dart';
import '../launcher/runtime_paths.dart';
import '../platform/denial_bridge_provider.dart';

/// Screen recording through the optional `screen-record` program
/// (Phonewave's services/screen/screen-record). Without the program on
/// `PATH` there is nothing to record with and the shade offers no tile.
///
/// The program owns the recording: the shell starts it, and starts it again
/// to stop it. While it records, `$XDG_RUNTIME_DIR/screen-record` names its
/// process, and the file goes once the video is finished; the state follows
/// that file.
class ScreenRecordingState {
  const ScreenRecordingState({
    this.available = false,
    this.recording = false,
    this.busy = false,
  });

  final bool available;
  final bool recording;

  /// Asked to start or stop, and the program has not answered yet.
  final bool busy;
}

final screenRecordingProvider =
    NotifierProvider<ScreenRecordingController, ScreenRecordingState>(
      ScreenRecordingController.new,
    );

class ScreenRecordingController extends Notifier<ScreenRecordingState> {
  /// How long a start or stop may take before the tile stops waiting.
  static const _answer = Duration(seconds: 5);

  String? _program;
  File? _state;
  Timer? _waiting;

  @override
  ScreenRecordingState build() {
    final paths = ref.watch(runtimePathsProvider);
    final program = _find(paths);
    final runtime = paths.environment['XDG_RUNTIME_DIR'] ?? '';
    _program = program;
    if (program == null || runtime.isEmpty) return const ScreenRecordingState();
    final file = File(p.join(runtime, 'screen-record'));
    _state = file;
    // The program writes the file aside and renames it into place.
    final subscription = Directory(runtime)
        .watch()
        .where(
          (event) =>
              p.basename(event.path) == 'screen-record' ||
              (event is FileSystemMoveEvent &&
                  p.basename(event.destination ?? '') == 'screen-record'),
        )
        .listen((_) => _follow(), onError: (Object _) {});
    ref.onDispose(subscription.cancel);
    ref.onDispose(() => _waiting?.cancel());
    return ScreenRecordingState(available: true, recording: _recording(file));
  }

  /// Starts recording, or stops the recording running.
  void toggle() {
    final program = _program;
    if (program == null || state.busy) return;
    if (!ref.read(denialBridgeProvider).launchApplication([
      program,
      'toggle',
    ])) {
      return;
    }
    state = ScreenRecordingState(
      available: true,
      recording: state.recording,
      busy: true,
    );
    _waiting?.cancel();
    _waiting = Timer(_answer, _follow);
  }

  void _follow() {
    final file = _state;
    if (!ref.mounted || file == null) return;
    _waiting?.cancel();
    _waiting = null;
    state = ScreenRecordingState(available: true, recording: _recording(file));
  }

  /// Whether the file names a process that still runs: one that crashed
  /// leaves its file behind.
  static bool _recording(File file) {
    try {
      final pid = int.tryParse(file.readAsLinesSync().first);
      return pid != null && Directory('/proc/$pid').existsSync();
    } on Object {
      return false;
    }
  }

  static String? _find(RuntimePaths paths) {
    for (final directory in (paths.environment['PATH'] ?? '').split(':')) {
      if (directory.isEmpty) continue;
      final candidate = p.join(directory, 'screen-record');
      final stat = FileStat.statSync(candidate);
      if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
        return candidate;
      }
    }
    return null;
  }
}
