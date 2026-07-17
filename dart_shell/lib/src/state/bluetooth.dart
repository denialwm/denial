import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bluetooth_service.dart';

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

  factory BluetoothState.initial() => BluetoothState(
        serviceAvailable: false,
        available: false,
        adapterName: '',
        powered: false,
        discovering: false,
        pairable: false,
        devices: const <BluetoothDeviceInfo>[],
        initializing: true,
        refreshing: false,
        scanning: false,
        powerChanging: false,
        busyDevices: const <String>{},
        pairingRequest: null,
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
    return BluetoothState(
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
      busyDevices: busyDevices ?? this.busyDevices,
      pairingRequest:
          clearPairingRequest ? null : pairingRequest ?? this.pairingRequest,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final bluetoothProvider =
    StateNotifierProvider<BluetoothController, BluetoothState>((ref) {
  return BluetoothController(ref.watch(bluetoothServiceProvider));
});

class BluetoothController extends StateNotifier<BluetoothState> {
  BluetoothController(this._service) : super(BluetoothState.initial()) {
    _snapshotSubscription = _service.snapshots.listen(_applySnapshot);
    _pairingSubscription = _service.pairingRequests.listen(_applyPairing);
    unawaited(_start());
  }

  static const Duration _scanDuration = Duration(seconds: 12);

  final BluetoothBackend _service;
  late final StreamSubscription<BluetoothSnapshot> _snapshotSubscription;
  late final StreamSubscription<BluetoothPairingRequest?> _pairingSubscription;
  Timer? _scanTimer;
  bool _scanStarting = false;
  bool _ownsDiscovery = false;

  Future<void> _start() async {
    try {
      await _service.start();
      _applySnapshot(_service.currentSnapshot);
      _applyPairing(_service.currentPairingRequest);
    } on Object {
      if (mounted) {
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
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      await _service.refresh();
    } on Object catch (error) {
      if (mounted) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (mounted) {
        state = state.copyWith(refreshing: false);
      }
    }
  }

  Future<void> togglePower() async {
    if (state.powerChanging || !state.available) {
      return;
    }
    state = state.copyWith(powerChanging: true, clearError: true);
    try {
      await _service.setPowered(!state.powered);
    } on Object catch (error) {
      if (mounted) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (mounted) {
        state = state.copyWith(powerChanging: false);
      }
    }
  }

  Future<void> scan() async {
    if (state.scanning || !state.available || !state.powered) {
      return;
    }
    _scanStarting = true;
    _ownsDiscovery = !state.discovering;
    state = state.copyWith(scanning: true, clearError: true);
    try {
      await _service.startDiscovery();
      if (!_ownsDiscovery) {
        if (mounted) {
          state = state.copyWith(scanning: false);
        }
        return;
      }
      _scanTimer?.cancel();
      _scanTimer = Timer(_scanDuration, () => unawaited(_finishScan()));
    } on Object catch (error) {
      _ownsDiscovery = false;
      if (mounted) {
        state = state.copyWith(
          scanning: false,
          error: _safeMessage(error),
        );
      }
    } finally {
      _scanStarting = false;
    }
  }

  Future<void> stopScan() => _finishScan();

  Future<void> _finishScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    final stopDiscovery = _ownsDiscovery;
    _ownsDiscovery = false;
    if (mounted && state.scanning) {
      state = state.copyWith(scanning: false);
    }
    if (stopDiscovery) {
      try {
        await _service.stopDiscovery();
      } on Object catch (error) {
        if (mounted) {
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
    final busy = Set<String>.of(state.busyDevices)..add(device.objectPath);
    state = state.copyWith(busyDevices: busy, clearError: true);
    try {
      await operation();
    } on Object catch (error) {
      if (mounted) {
        state = state.copyWith(error: _safeMessage(error));
      }
    } finally {
      if (mounted) {
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

  void _applySnapshot(BluetoothSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final scanEnded = state.scanning &&
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

  void _applyPairing(BluetoothPairingRequest? request) {
    if (!mounted) {
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
        'org.bluez.Error.Rejected' =>
          'Bluetooth pairing was cancelled',
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

  @override
  void dispose() {
    _scanTimer?.cancel();
    unawaited(_snapshotSubscription.cancel());
    unawaited(_pairingSubscription.cancel());
    super.dispose();
  }
}

String bluetoothStatusLabel(BluetoothState state) {
  if (state.initializing) {
    return 'Loading BlueZ…';
  }
  if (!state.serviceAvailable) {
    return 'BlueZ unavailable';
  }
  if (!state.available) {
    return 'No adapter';
  }
  if (!state.powered) {
    return 'Off';
  }
  final connected = state.devices.where((device) => device.connected).toList();
  if (connected.isNotEmpty) {
    return connected.length == 1
        ? connected.first.name
        : '${connected.length} devices connected';
  }
  if (state.discovering) {
    return 'Scanning…';
  }
  return 'On';
}
