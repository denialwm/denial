import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/network_service.dart';
import 'notifier_lifecycle.dart';

final networkConnectivityProvider =
    NotifierProvider<NetworkConnectivityController, NetworkConnectivityState>(
      NetworkConnectivityController.new,
    );

@immutable
class NetworkConnectivityState {
  NetworkConnectivityState({
    required this.snapshot,
    required this.initializing,
    required this.scanning,
    required this.radioChanging,
    required Set<String> busyNetworks,
    this.error,
  }) : busyNetworks = Set<String>.unmodifiable(busyNetworks);

  NetworkConnectivityState.initial()
    : snapshot = NetworkSnapshot.unavailable(),
      initializing = true,
      scanning = false,
      radioChanging = false,
      busyNetworks = const <String>{},
      error = null;

  final NetworkSnapshot snapshot;
  final bool initializing;
  final bool scanning;
  final bool radioChanging;
  final Set<String> busyNetworks;
  final String? error;

  NetworkConnectivityState copyWith({
    NetworkSnapshot? snapshot,
    bool? initializing,
    bool? scanning,
    bool? radioChanging,
    Set<String>? busyNetworks,
    String? error,
    bool clearError = false,
  }) {
    return NetworkConnectivityState(
      snapshot: snapshot ?? this.snapshot,
      initializing: initializing ?? this.initializing,
      scanning: scanning ?? this.scanning,
      radioChanging: radioChanging ?? this.radioChanging,
      busyNetworks: busyNetworks ?? this.busyNetworks,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class NetworkConnectivityController extends Notifier<NetworkConnectivityState>
    with NotifierLifecycle<NetworkConnectivityState> {
  @override
  NetworkConnectivityState build() {
    _service = ref.watch(networkServiceProvider);
    _scanTimer = null;
    _scanBaseline = -1;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _service.snapshots.listen(
      (snapshot) => _applySnapshot(snapshot, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      _scanTimer?.cancel();
      _scanTimer = null;
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        unawaited(_start(generation));
      }
    });
    return NetworkConnectivityState.initial();
  }

  static const Duration _scanFallback = Duration(seconds: 15);

  late NetworkBackend _service;
  late int _buildGeneration;
  Timer? _scanTimer;
  int _scanBaseline = -1;

  Future<void> _start(int generation) async {
    try {
      await _service.start();
      _applySnapshot(_service.currentSnapshot, generation);
    } on Object {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          initializing: false,
          error: 'Network service is unavailable',
        );
      }
    }
  }

  Future<void> refresh() async {
    final generation = _buildGeneration;
    try {
      await _service.refresh();
    } on Object {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: 'Unable to refresh network state');
      }
    }
  }

  Future<void> toggleWireless() =>
      setWirelessEnabled(!state.snapshot.wirelessEnabled);

  Future<void> setWirelessEnabled(bool enabled) async {
    if (state.radioChanging ||
        !state.snapshot.serviceAvailable ||
        !state.snapshot.wifiDeviceAvailable ||
        !state.snapshot.wirelessHardwareEnabled ||
        state.snapshot.radioPermission == NetworkPermission.denied) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(radioChanging: true, clearError: true);
    try {
      await _service.setWirelessEnabled(enabled);
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(radioChanging: false);
      }
    }
  }

  Future<void> scan() async {
    if (state.scanning ||
        !state.snapshot.serviceAvailable ||
        !state.snapshot.wifiDeviceAvailable ||
        !state.snapshot.wirelessHardwareEnabled ||
        !state.snapshot.wirelessEnabled ||
        state.snapshot.controlPermission == NetworkPermission.denied) {
      return;
    }
    final generation = _buildGeneration;
    _scanBaseline = state.snapshot.lastScan;
    state = state.copyWith(scanning: true, clearError: true);
    _scanTimer?.cancel();
    _scanTimer = Timer(_scanFallback, () => _finishScan(generation));
    try {
      await _service.requestScan();
    } on Object catch (error) {
      _finishScan(generation);
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: _safeMessage(error));
      }
    }
  }

  Future<void> connect(WifiNetwork network, {String? password}) {
    if (state.snapshot.controlPermission == NetworkPermission.denied ||
        (!network.saved &&
            state.snapshot.modifyPermission == NetworkPermission.denied)) {
      state = state.copyWith(error: 'Wi-Fi changes are not permitted');
      return Future<void>.value();
    }
    return _withNetworkBusy(
      network,
      () => _service.connect(network, password: password),
    );
  }

  Future<void> disconnect(WifiNetwork network) {
    if (state.snapshot.controlPermission == NetworkPermission.denied) {
      state = state.copyWith(error: 'Wi-Fi changes are not permitted');
      return Future<void>.value();
    }
    return _withNetworkBusy(network, _service.disconnect);
  }

  Future<void> forget(WifiNetwork network) {
    if (state.snapshot.modifyPermission == NetworkPermission.denied) {
      state = state.copyWith(error: 'Saved networks cannot be modified');
      return Future<void>.value();
    }
    return _withNetworkBusy(network, () => _service.forget(network));
  }

  Future<void> _withNetworkBusy(
    WifiNetwork network,
    Future<void> Function() operation,
  ) async {
    if (state.busyNetworks.contains(network.identity)) {
      return;
    }
    final generation = _buildGeneration;
    final busy = Set<String>.of(state.busyNetworks)..add(network.identity);
    state = state.copyWith(busyNetworks: busy, clearError: true);
    try {
      await operation();
      await _service.refresh();
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        final remaining = Set<String>.of(state.busyNetworks)
          ..remove(network.identity);
        state = state.copyWith(busyNetworks: remaining);
      }
    }
  }

  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  void _applySnapshot(NetworkSnapshot snapshot, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final scanCompleted =
        state.scanning &&
        snapshot.lastScan >= 0 &&
        snapshot.lastScan != _scanBaseline;
    if (scanCompleted || !snapshot.serviceAvailable) {
      _scanTimer?.cancel();
      _scanTimer = null;
    }
    state = state.copyWith(
      snapshot: snapshot,
      initializing: false,
      scanning: scanCompleted || !snapshot.serviceAvailable
          ? false
          : state.scanning,
    );
  }

  void _finishScan(int generation) {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (isBuildGenerationActive(generation) && state.scanning) {
      state = state.copyWith(scanning: false);
    }
  }

  String _safeMessage(Object error) {
    if (error is StateError) {
      return error.message;
    }
    if (error is ArgumentError) {
      return error.message?.toString() ?? 'Invalid network settings';
    }
    return 'The network service could not complete the request';
  }
}
