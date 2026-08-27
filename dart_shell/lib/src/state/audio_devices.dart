import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_service.dart';
import 'notifier_lifecycle.dart';

final audioDevicesProvider =
    NotifierProvider<AudioDevicesController, AudioDevicesState>(
      AudioDevicesController.new,
    );

@immutable
class AudioDevicesState {
  const AudioDevicesState({
    required this.devices,
    required this.loading,
    required this.changing,
    required this.error,
  });

  const AudioDevicesState.initial()
    : devices = const <AudioOutputDevice>[],
      loading = true,
      changing = false,
      error = null;

  final List<AudioOutputDevice> devices;
  final bool loading;
  final bool changing;
  final String? error;

  AudioOutputDevice? get activeDevice {
    for (final device in devices) {
      if (device.active) {
        return device;
      }
    }
    return null;
  }

  AudioDevicesState copyWith({
    List<AudioOutputDevice>? devices,
    bool? loading,
    bool? changing,
    String? error,
    bool clearError = false,
  }) {
    return AudioDevicesState(
      devices: devices ?? this.devices,
      loading: loading ?? this.loading,
      changing: changing ?? this.changing,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class AudioDevicesController extends Notifier<AudioDevicesState>
    with NotifierLifecycle<AudioDevicesState> {
  static const Duration _responseTimeout = Duration(seconds: 2);

  @override
  AudioDevicesState build() {
    _audio = ref.watch(audioServiceProvider);
    _responseTimer = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _audio.outputDeviceStates.listen(
      (devices) => _handleDevices(devices, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      _responseTimer?.cancel();
      _responseTimer = null;
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        refresh();
      }
    });
    return const AudioDevicesState.initial();
  }

  late AudioService _audio;
  late int _buildGeneration;
  Timer? _responseTimer;

  void refresh() {
    state = state.copyWith(loading: state.devices.isEmpty, clearError: true);
    _audio.requestOutputDevices();
    _armResponseTimeout();
  }

  void select(String name) {
    if (state.changing ||
        !state.devices.any(
          (device) => device.name == name && device.available,
        ) ||
        state.activeDevice?.name == name) {
      return;
    }
    state = state.copyWith(
      devices: List<AudioOutputDevice>.unmodifiable(
        state.devices.map(
          (device) => AudioOutputDevice(
            name: device.name,
            description: device.description,
            active: device.name == name,
            available: device.available,
          ),
        ),
      ),
      changing: true,
      clearError: true,
    );
    _audio.selectOutputDevice(name);
    _armResponseTimeout();
  }

  void _handleDevices(List<AudioOutputDevice> devices, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    _responseTimer?.cancel();
    _responseTimer = null;
    state = AudioDevicesState(
      devices: devices,
      loading: false,
      changing: false,
      error: null,
    );
  }

  void _armResponseTimeout() {
    _responseTimer?.cancel();
    final generation = _buildGeneration;
    _responseTimer = Timer(_responseTimeout, () {
      if (!isBuildGenerationActive(generation)) {
        return;
      }
      final wasChanging = state.changing;
      state = state.copyWith(
        loading: false,
        changing: false,
        error: 'Unable to read audio output devices.',
      );
      if (wasChanging) {
        _audio.requestOutputDevices();
      }
    });
  }
}
