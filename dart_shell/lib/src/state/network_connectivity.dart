import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/network_manager_service.dart';

final networkConnectivityProvider = StateNotifierProvider<
    NetworkConnectivityController, NetworkConnectivityState>((ref) {
  return NetworkConnectivityController(
    ref.watch(networkManagerServiceProvider),
  );
});

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
      : snapshot = NetworkManagerSnapshot.unavailable(),
        initializing = true,
        scanning = false,
        radioChanging = false,
        busyNetworks = const <String>{},
        error = null;

  final NetworkManagerSnapshot snapshot;
  final bool initializing;
  final bool scanning;
  final bool radioChanging;
  final Set<String> busyNetworks;
  final String? error;

  NetworkConnectivityState copyWith({
    NetworkManagerSnapshot? snapshot,
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

class NetworkConnectivityController
    extends StateNotifier<NetworkConnectivityState> {
  NetworkConnectivityController(this._service)
      : super(NetworkConnectivityState.initial()) {
    _subscription = _service.snapshots.listen(_applySnapshot);
    unawaited(_start());
  }

  static const Duration _scanFallback = Duration(seconds: 15);

  final NetworkManagerBackend _service;
  late final StreamSubscription<NetworkManagerSnapshot> _subscription;
  Timer? _scanTimer;
  int _scanBaseline = -1;

  Future<void> _start() async {
    try {
      await _service.start();
      _applySnapshot(_service.currentSnapshot);
    } on Object {
      if (mounted) {
        state = state.copyWith(
          initializing: false,
          error: 'NetworkManager is unavailable',
        );
      }
    }
  }

  Future<void> refresh() async {
    try {
      await _service.refresh();
    } on Object {
      if (mounted) {
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
    state = state.copyWith(radioChanging: true, clearError: true);
    try {
      await _service.setWirelessEnabled(enabled);
    } on Object catch (error) {
      if (mounted) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (mounted) {
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
    _scanBaseline = state.snapshot.lastScan;
    state = state.copyWith(scanning: true, clearError: true);
    _scanTimer?.cancel();
    _scanTimer = Timer(_scanFallback, _finishScan);
    try {
      await _service.requestScan();
    } on Object catch (error) {
      _finishScan();
      if (mounted) {
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
    final busy = Set<String>.of(state.busyNetworks)..add(network.identity);
    state = state.copyWith(busyNetworks: busy, clearError: true);
    try {
      await operation();
      await _service.refresh();
    } on Object catch (error) {
      if (mounted) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (mounted) {
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

  void _applySnapshot(NetworkManagerSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final scanCompleted = state.scanning &&
        snapshot.lastScan >= 0 &&
        snapshot.lastScan != _scanBaseline;
    if (scanCompleted || !snapshot.serviceAvailable) {
      _scanTimer?.cancel();
      _scanTimer = null;
    }
    state = state.copyWith(
      snapshot: snapshot,
      initializing: false,
      scanning:
          scanCompleted || !snapshot.serviceAvailable ? false : state.scanning,
    );
  }

  void _finishScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (mounted && state.scanning) {
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
    return 'NetworkManager could not complete the request';
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
