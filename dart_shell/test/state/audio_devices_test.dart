import 'dart:async';

import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/audio_service.dart';
import 'package:denial_dart_shell/src/state/audio_devices.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio devices follow native state and select optimistically', () async {
    final bridge = DenialBridge();
    final audio = _FakeAudioService(bridge);
    addTearDown(audio.dispose);
    final container = ProviderContainer.test(
      overrides: [audioServiceProvider.overrideWithValue(audio)],
    );
    final controller = container.read(audioDevicesProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    expect(audio.refreshes, 1);
    audio.emit(const <AudioOutputDevice>[
      AudioOutputDevice(
        name: 'speaker',
        description: 'Built-in Speakers',
        active: true,
        available: true,
      ),
      AudioOutputDevice(
        name: 'headset',
        description: 'USB Headset',
        active: false,
        available: true,
      ),
    ]);
    expect(container.read(audioDevicesProvider).loading, isFalse);
    expect(container.read(audioDevicesProvider).activeDevice?.name, 'speaker');

    controller.select('headset');
    expect(audio.selections, <String>['headset']);
    expect(container.read(audioDevicesProvider).changing, isTrue);
    expect(container.read(audioDevicesProvider).activeDevice?.name, 'headset');

    audio.emit(const <AudioOutputDevice>[
      AudioOutputDevice(
        name: 'speaker',
        description: 'Built-in Speakers',
        active: false,
        available: true,
      ),
      AudioOutputDevice(
        name: 'headset',
        description: 'USB Headset',
        active: true,
        available: true,
      ),
    ]);
    expect(container.read(audioDevicesProvider).changing, isFalse);
    expect(
      container.read(audioDevicesProvider).activeDevice?.description,
      'USB Headset',
    );
  });

  test('explicitly unavailable devices cannot be selected', () async {
    final bridge = DenialBridge();
    final audio = _FakeAudioService(bridge);
    addTearDown(audio.dispose);
    final container = ProviderContainer.test(
      overrides: [audioServiceProvider.overrideWithValue(audio)],
    );
    final controller = container.read(audioDevicesProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    audio.emit(const <AudioOutputDevice>[
      AudioOutputDevice(
        name: 'speaker',
        description: 'Speaker',
        active: true,
        available: true,
      ),
      AudioOutputDevice(
        name: 'headphones',
        description: 'Headphones',
        active: false,
        available: false,
      ),
    ]);

    controller.select('headphones');

    expect(audio.selections, isEmpty);
    expect(container.read(audioDevicesProvider).changing, isFalse);
    expect(container.read(audioDevicesProvider).activeDevice?.name, 'speaker');
  });
}

class _FakeAudioService extends AudioService {
  _FakeAudioService(this.bridge) : super(bridge);

  final DenialBridge bridge;
  final StreamController<List<AudioOutputDevice>> _devices =
      StreamController<List<AudioOutputDevice>>.broadcast(sync: true);
  final List<String> selections = <String>[];
  int refreshes = 0;

  @override
  Stream<List<AudioOutputDevice>> get outputDeviceStates => _devices.stream;

  @override
  void requestOutputDevices() {
    refreshes += 1;
  }

  @override
  void selectOutputDevice(String name) {
    selections.add(name);
  }

  void emit(List<AudioOutputDevice> devices) => _devices.add(devices);

  Future<void> dispose() async {
    await _devices.close();
    bridge.dispose();
  }
}
