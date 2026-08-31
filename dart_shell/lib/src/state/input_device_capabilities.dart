import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/input_device_capabilities.dart';
import '../platform/denial_bridge.dart';
import 'shell_controller.dart';

class InputDeviceCapabilitiesState {
  const InputDeviceCapabilitiesState({
    this.capabilities = const DenialInputDeviceCapabilities.none(),
    this.busy = false,
    this.error,
  });

  final DenialInputDeviceCapabilities capabilities;
  final bool busy;
  final String? error;

  InputDeviceCapabilitiesState copyWith({
    DenialInputDeviceCapabilities? capabilities,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return InputDeviceCapabilitiesState(
      capabilities: capabilities ?? this.capabilities,
      busy: busy ?? this.busy,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final inputDeviceCapabilitiesProvider =
    NotifierProvider<
      InputDeviceCapabilitiesController,
      InputDeviceCapabilitiesState
    >(InputDeviceCapabilitiesController.new);

class InputDeviceCapabilitiesController
    extends Notifier<InputDeviceCapabilitiesState> {
  late DenialBridge _bridge;
  StreamSubscription<DenialInputDeviceCapabilities>? _subscription;
  var _generation = 0;

  @override
  InputDeviceCapabilitiesState build() {
    _bridge = ref.watch(denialBridgeProvider);
    unawaited(_subscription?.cancel());
    final generation = ++_generation;
    _subscription = _bridge.inputDeviceCapabilities.listen((capabilities) {
      if (generation == _generation) {
        state = state.copyWith(
          capabilities: capabilities,
          busy: false,
          clearError: true,
        );
      }
    });
    ref.onDispose(() {
      _generation += 1;
      unawaited(_subscription?.cancel());
      _subscription = null;
    });
    scheduleMicrotask(() => unawaited(_refresh(generation)));
    return const InputDeviceCapabilitiesState();
  }

  void setTapToClick(bool enabled) {
    unawaited(
      _configure(state.capabilities.copyWith(tapToClickEnabled: enabled)),
    );
  }

  void setNaturalScroll(bool enabled) {
    unawaited(
      _configure(state.capabilities.copyWith(naturalScrollEnabled: enabled)),
    );
  }

  void setScrollSpeedFactor(double factor) {
    unawaited(
      _configure(state.capabilities.copyWith(scrollSpeedFactor: factor)),
    );
  }

  void setMouseSpeed(double speed) {
    unawaited(_configureMouse(state.capabilities.copyWith(mouseSpeed: speed)));
  }

  Future<void> _refresh(int generation) async {
    try {
      final capabilities = await _bridge.readInputDeviceCapabilities();
      if (generation == _generation) {
        state = state.copyWith(
          capabilities: capabilities,
          busy: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(busy: false, error: error.toString());
      }
    }
  }

  Future<void> _configure(DenialInputDeviceCapabilities requested) async {
    if (state.busy || requested.revision <= 0 || !requested.hasTouchpad) {
      return;
    }
    final generation = _generation;
    var fallback = state.capabilities;
    state = state.copyWith(
      capabilities: requested,
      busy: true,
      clearError: true,
    );
    try {
      DenialInputDeviceCapabilities applied;
      try {
        applied = await _bridge.configureTouchpad(requested);
      } on StateError {
        final latest = await _bridge.readInputDeviceCapabilities();
        fallback = latest;
        applied = await _bridge.configureTouchpad(
          requested.copyWith(
            revision: latest.revision,
            hasTouchpad: latest.hasTouchpad,
          ),
        );
      }
      if (generation == _generation) {
        state = state.copyWith(
          capabilities: applied,
          busy: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(
          capabilities: fallback,
          busy: false,
          error: error.toString(),
        );
      }
    }
  }

  Future<void> _configureMouse(DenialInputDeviceCapabilities requested) async {
    if (state.busy || requested.revision <= 0 || !requested.hasMouse) {
      return;
    }
    final generation = _generation;
    var fallback = state.capabilities;
    state = state.copyWith(
      capabilities: requested,
      busy: true,
      clearError: true,
    );
    try {
      DenialInputDeviceCapabilities applied;
      try {
        applied = await _bridge.configureMouse(requested);
      } on StateError {
        final latest = await _bridge.readInputDeviceCapabilities();
        fallback = latest;
        applied = await _bridge.configureMouse(
          requested.copyWith(
            revision: latest.revision,
            hasMouse: latest.hasMouse,
          ),
        );
      }
      if (generation == _generation) {
        state = state.copyWith(
          capabilities: applied,
          busy: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(
          capabilities: fallback,
          busy: false,
          error: error.toString(),
        );
      }
    }
  }
}
