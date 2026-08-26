import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bluetooth_service.dart';
import 'notifier_lifecycle.dart';

@immutable
class BluetoothState {
  BluetoothState({
    required this.serviceAvailable,
    required this.available,
    required this.adapterName,
    required this.powered,
    required this.discovering,
    required this.pairable,
    required this.devices,
    required this.initializing,
    required this.refreshing,
    required this.scanning,
    required this.powerChanging,
    required Set<String> busyDevices,
    required this.pairingRequest,
    this.error,
  }) : busyDevices = Set<String>.unmodifiable(busyDevices);

  const BluetoothState._({
    required this.serviceAvailable,
    required this.available,
    required this.adapterName,
    required this.powered,
    required this.discovering,
    required this.pairable,
    required this.devices,
    required this.initializing,
    required this.refreshing,
    required this.scanning,
    required this.powerChanging,
    required this.busyDevices,
    required this.pairingRequest,
    required this.error,
  });

  factory BluetoothState.initial() => const BluetoothState._(
    serviceAvailable: false,
    available: false,
    adapterName: '',
    powered: false,
    discovering: false,
    pairable: false,
    devices: <BluetoothDeviceInfo>[],
    initializing: true,
    refreshing: false,
    scanning: false,
    powerChanging: false,
    busyDevices: <String>{},
    pairingRequest: null,
    error: null,
  );

  final bool serviceAvailable;
  final bool available;
  final String adapterName;
  final bool powered;
  final bool discovering;
  final bool pairable;
  final List<BluetoothDeviceInfo> devices;
  final bool initializing;
  final bool refreshing;
  final bool scanning;
  final bool powerChanging;
  final Set<String> busyDevices;
  final BluetoothPairingRequest? pairingRequest;
  final String? error;

  BluetoothState copyWith({
    bool? serviceAvailable,
    bool? available,
    String? adapterName,
    bool? powered,
    bool? discovering,
    bool? pairable,
    List<BluetoothDeviceInfo>? devices,
    bool? initializing,
    bool? refreshing,
    bool? scanning,
    bool? powerChanging,
    Set<String>? busyDevices,
    BluetoothPairingRequest? pairingRequest,
    bool clearPairingRequest = false,
    String? error,
    bool clearError = false,
  }) {
    return BluetoothState._(
      serviceAvailable: serviceAvailable ?? this.serviceAvailable,
      available: available ?? this.available,
      adapterName: adapterName ?? this.adapterName,
      powered: powered ?? this.powered,
      discovering: discovering ?? this.discovering,
      pairable: pairable ?? this.pairable,
      devices: devices ?? this.devices,
      initializing: initializing ?? this.initializing,
      refreshing: refreshing ?? this.refreshing,
      scanning: scanning ?? this.scanning,
      powerChanging: powerChanging ?? this.powerChanging,
      busyDevices: busyDevices == null
          ? this.busyDevices
          : Set<String>.unmodifiable(busyDevices),
      pairingRequest: clearPairingRequest
          ? null
          : pairingRequest ?? this.pairingRequest,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final bluetoothProvider = NotifierProvider<BluetoothController, BluetoothState>(
  BluetoothController.new,
);

class BluetoothController extends Notifier<BluetoothState>
    with NotifierLifecycle<BluetoothState> {
  @override
  BluetoothState build() {
    _service = ref.watch(bluetoothServiceProvider);
    _scanTimer = null;
    _scanStarting = false;
    _ownsDiscovery = false;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final snapshotSubscription = _service.snapshots.listen(
      (snapshot) => _applySnapshot(snapshot, generation),
    );
    final pairingSubscription = _service.pairingRequests.listen(
      (request) => _applyPairing(request, generation),
    );
    cancelOnDispose(snapshotSubscription);
    cancelOnDispose(pairingSubscription);
    ref.onDispose(() {
      _scanTimer?.cancel();
      _scanTimer = null;
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        unawaited(_start(generation));
      }
    });
    return BluetoothState.initial();
  }

  static const Duration _scanDuration = Duration(seconds: 12);

  late BluetoothBackend _service;
  late int _buildGeneration;
  Timer? _scanTimer;
  bool _scanStarting = false;
  bool _ownsDiscovery = false;

  Future<void> _start(int generation) async {
    try {
      await _service.start();
      _applySnapshot(_service.currentSnapshot, generation);
      _applyPairing(_service.currentPairingRequest, generation);
    } on Object {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          initializing: false,
          error: 'Bluetooth service is unavailable',
        );
      }
    }
  }

  Future<void> refresh() async {
    if (state.refreshing) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      await _service.refresh();
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(refreshing: false);
      }
    }
  }

  Future<void> togglePower() async {
    if (state.powerChanging || !state.available) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(powerChanging: true, clearError: true);
    try {
      await _service.setPowered(!state.powered);
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(powerChanging: false);
      }
    }
  }

  Future<void> scan() async {
    if (state.scanning || !state.available || !state.powered) {
      return;
    }
    final generation = _buildGeneration;
    _scanStarting = true;
    _ownsDiscovery = !state.discovering;
    state = state.copyWith(scanning: true, clearError: true);
    try {
      await _service.startDiscovery();
      if (!_ownsDiscovery) {
        if (isBuildGenerationActive(generation)) {
          state = state.copyWith(scanning: false);
        }
        return;
      }
      _scanTimer?.cancel();
      _scanTimer = Timer(
        _scanDuration,
        () => unawaited(_finishScan(generation)),
      );
    } on Object catch (error) {
      _ownsDiscovery = false;
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(scanning: false, error: _safeMessage(error));
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        _scanStarting = false;
      }
    }
  }

  Future<void> stopScan() => _finishScan(_buildGeneration);

  Future<void> _finishScan(int generation) async {
    _scanTimer?.cancel();
    _scanTimer = null;
    final stopDiscovery = _ownsDiscovery;
    _ownsDiscovery = false;
    if (isBuildGenerationActive(generation) && state.scanning) {
      state = state.copyWith(scanning: false);
    }
    if (stopDiscovery) {
      try {
        await _service.stopDiscovery();
      } on Object catch (error) {
        if (isBuildGenerationActive(generation)) {
          state = state.copyWith(error: _safeMessage(error));
        }
      }
    }
  }

  Future<void> pair(BluetoothDeviceInfo device) {
    return _withDeviceBusy(device, () => _service.pair(device));
  }

  Future<void> toggleTrust(BluetoothDeviceInfo device) {
    return _withDeviceBusy(
      device,
      () => _service.setTrusted(device, !device.trusted),
    );
  }

  Future<void> toggleConnection(BluetoothDeviceInfo device) {
    return _withDeviceBusy(device, () async {
      if (device.connected) {
        await _service.disconnect(device);
        return;
      }
      if (!device.paired) {
        await _service.pair(device);
      }
      if (!device.trusted) {
        await _service.setTrusted(device, true);
      }
      await _service.connect(device);
    });
  }

  Future<void> remove(BluetoothDeviceInfo device) {
    return _withDeviceBusy(device, () => _service.remove(device));
  }

  Future<void> _withDeviceBusy(
    BluetoothDeviceInfo device,
    Future<void> Function() operation,
  ) async {
    if (state.busyDevices.contains(device.objectPath)) {
      return;
    }
    final generation = _buildGeneration;
    final busy = Set<String>.of(state.busyDevices)..add(device.objectPath);
    state = state.copyWith(busyDevices: busy, clearError: true);
    try {
      await operation();
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (isBuildGenerationActive(generation)) {
        final remaining = Set<String>.of(state.busyDevices)
          ..remove(device.objectPath);
        state = state.copyWith(busyDevices: remaining);
      }
    }
  }

  void respondToPairing({required bool accepted, String? response}) {
    final request = state.pairingRequest;
    if (request == null) {
      return;
    }
    _service.respondToPairing(
      request.id,
      accepted: accepted,
      response: response,
    );
  }

  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  void _applySnapshot(BluetoothSnapshot snapshot, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final scanEnded =
        state.scanning &&
        !_scanStarting &&
        (!snapshot.serviceAvailable ||
            !snapshot.available ||
            !snapshot.powered ||
            !snapshot.discovering);
    if (scanEnded) {
      _scanTimer?.cancel();
      _scanTimer = null;
      _ownsDiscovery = false;
    }
    state = state.copyWith(
      serviceAvailable: snapshot.serviceAvailable,
      available: snapshot.available,
      adapterName: snapshot.adapterName,
      powered: snapshot.powered,
      discovering: snapshot.discovering,
      pairable: snapshot.pairable,
      devices: snapshot.devices,
      initializing: false,
      refreshing: false,
      scanning: scanEnded ? false : state.scanning,
    );
  }

  void _applyPairing(BluetoothPairingRequest? request, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    state = request == null
        ? state.copyWith(clearPairingRequest: true)
        : state.copyWith(pairingRequest: request);
  }

  String _safeMessage(Object error) {
    if (error is StateError) {
      return error.message;
    }
    if (error is DBusMethodResponseException) {
      return switch (error.errorName) {
        'org.bluez.Error.AuthenticationCanceled' ||
        'org.bluez.Error.Canceled' ||
        'org.bluez.Error.Rejected' => 'Bluetooth pairing was cancelled',
        'org.bluez.Error.AuthenticationFailed' ||
        'org.bluez.Error.AuthenticationRejected' =>
          'Bluetooth authentication failed',
        'org.bluez.Error.AuthenticationTimeout' =>
          'Bluetooth pairing timed out',
        'org.bluez.Error.NotReady' => 'The Bluetooth adapter is not ready',
        'org.bluez.Error.InProgress' =>
          'A Bluetooth operation is already in progress',
        _ => 'Bluetooth could not complete the request',
      };
    }
    return 'Bluetooth could not complete the request';
  }
}
