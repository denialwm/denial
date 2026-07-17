import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/audio_service.dart';
import 'package:denial_dart_shell/src/state/app_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('per-app volume stays optimistic until native acknowledgement',
      () async {
    final bridge = DenialBridge();
    final audio = _FakeAudioService(bridge);
    final controller = AppAudioController(audio);
    try {
      controller.refresh();
      expect(audio.refreshes, 1);

      audio.emit(const <AppAudioStream>[
        AppAudioStream(
          id: 7,
          name: 'Firefox',
          level: 0.30,
          muted: false,
        ),
      ]);
      expect(controller.state.loading, isFalse);
      expect(controller.state.streams.single.level, 0.30);

      controller.commitVolume(7, 0.75);
      expect(audio.writes, const <({int id, int percent})>[
        (id: 7, percent: 75),
      ]);

      audio.emit(const <AppAudioStream>[
        AppAudioStream(
          id: 7,
          name: 'Firefox',
          level: 0.40,
          muted: false,
        ),
      ]);
      expect(
        controller.state.streams.single.level,
        0.75,
        reason: 'an older native snapshot must not pull back the slider',
      );

      audio.emit(const <AppAudioStream>[
        AppAudioStream(
          id: 7,
          name: 'Firefox',
          level: 0.75,
          muted: false,
        ),
      ]);
      audio.emit(const <AppAudioStream>[
        AppAudioStream(
          id: 7,
          name: 'Firefox',
          level: 0.55,
          muted: false,
        ),
      ]);
      expect(controller.state.streams.single.level, 0.55);
    } finally {
      controller.dispose();
      await audio.dispose();
    }
  });
}

class _FakeAudioService extends AudioService {
  _FakeAudioService(this.bridge) : super(bridge);

  final DenialBridge bridge;
  final StreamController<List<AppAudioStream>> _states =
      StreamController<List<AppAudioStream>>.broadcast(sync: true);
  final List<({int id, int percent})> writes = <({int id, int percent})>[];
  int refreshes = 0;

  @override
  Stream<List<AppAudioStream>> get appStreamStates => _states.stream;

  @override
  void requestAppStreams() {
    refreshes += 1;
  }

  @override
  void applyAppStream(int streamId, int percent) {
    writes.add((id: streamId, percent: percent));
  }

  void emit(List<AppAudioStream> streams) {
    _states.add(streams);
  }

  Future<void> dispose() async {
    await _states.close();
    bridge.dispose();
  }
}
