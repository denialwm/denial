import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../state/shell_controller.dart';

final audioServiceProvider = Provider<AudioService>((ref) {
  return AudioService(ref.watch(denialBridgeProvider));
});

class AudioLevelState {
  const AudioLevelState({required this.level, required this.requestSerial});

  final double level;
  final int requestSerial;
}

class AppAudioStream {
  const AppAudioStream({
    required this.id,
    required this.name,
    required this.level,
    required this.muted,
  });

  final int id;
  final String name;
  final double level;
  final bool muted;

  AppAudioStream copyWith({double? level, bool? muted}) {
    return AppAudioStream(
      id: id,
      name: name,
      level: level ?? this.level,
      muted: muted ?? this.muted,
    );
  }
}

/// Controls the default output through deniald's persistent native audio
/// bridge. The embedded Dart runtime must never spawn a CLI for this path.
class AudioService {
  const AudioService(this._bridge);

  final DenialBridge _bridge;

  /// Reads the current default-sink volume as a normalized value.
  Future<double?> readLevel() => _bridge.readAudioLevel();

  Stream<AudioLevelState> get states => _bridge.audioStates.map(
    (state) =>
        AudioLevelState(level: state.level, requestSerial: state.requestSerial),
  );

  Stream<List<AppAudioStream>> get appStreamStates =>
      _bridge.audioStreamStates.map(
        (streams) => List<AppAudioStream>.unmodifiable(
          streams.map(
            (stream) => AppAudioStream(
              id: stream.id,
              name: stream.name,
              level: stream.level,
              muted: stream.muted,
            ),
          ),
        ),
      );

  Future<void> apply(int percent, {required int requestSerial}) {
    _bridge.setAudioLevel(percent, requestSerial: requestSerial);
    return Future<void>.value();
  }

  void requestAppStreams() => _bridge.requestAudioStreams();

  void applyAppStream(int streamId, int percent) {
    _bridge.setAudioStreamLevel(streamId, percent);
  }
}
