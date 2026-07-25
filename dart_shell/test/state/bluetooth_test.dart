import 'dart:async';

import 'package:denial_dart_shell/src/services/bluetooth_service.dart';
import 'package:denial_dart_shell/src/state/bluetooth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'controller converges to signals and serializes adapter/device actions',
    () async {
      final backend = _FakeBluetoothBackend();
      addTearDown(backend.dispose);
      final container = ProviderContainer.test(
        overrides: [bluetoothServiceProvider.overrideWithValue(backend)],
      );
      final controller = container.read(bluetoothProvider.notifier);
      await _settle();

      expect(backend.started, isTrue);
      expect(container.read(bluetoothProvider).initializing, isFalse);
      expect(container.read(bluetoothProvider).powered, isTrue);

      backend.powerGate = Completer<void>();
      final firstPower = controller.togglePower();
      final duplicatePower = controller.togglePower();
      expect(backend.powerWrites, <bool>[false]);
      backend.powerGate!.complete();
      await Future.wait(<Future<void>>[firstPower, duplicatePower]);
      expect(container.read(bluetoothProvider).powered, isFalse);

      backend.emit(_snapshot(powered: true));
      await controller.scan();
      expect(backend.discoveryStarts, 1);
      expect(container.read(bluetoothProvider).scanning, isTrue);
      expect(container.read(bluetoothProvider).discovering, isTrue);
      await controller.stopScan();
      expect(backend.discoveryStops, 1);
      expect(container.read(bluetoothProvider).scanning, isFalse);

      final device = container.read(bluetoothProvider).devices.single;
      backend.deviceGate = Completer<void>();
      final firstConnection = controller.toggleConnection(device);
      final duplicateConnection = controller.toggleConnection(device);
      expect(backend.pairCalls, 1);
      expect(container.read(bluetoothProvider).busyDevices, <String>{
        device.objectPath,
      });
      backend.deviceGate!.complete();
      await Future.wait(<Future<void>>[firstConnection, duplicateConnection]);
      expect(backend.trustWrites, <bool>[true]);
      expect(backend.connectCalls, 1);
      expect(container.read(bluetoothProvider).busyDevices, isEmpty);

      backend.emit(const BluetoothSnapshot.unavailable());
      expect(container.read(bluetoothProvider).serviceAvailable, isFalse);
      expect(container.read(bluetoothProvider).available, isFalse);
    },
  );

  test(
    'pairing responses are one-shot and backend errors are sanitized',
    () async {
      final backend = _FakeBluetoothBackend();
      addTearDown(backend.dispose);
      final container = ProviderContainer.test(
        overrides: [bluetoothServiceProvider.overrideWithValue(backend)],
      );
      final controller = container.read(bluetoothProvider.notifier);
      await _settle();

      const request = BluetoothPairingRequest(
        id: 7,
        kind: BluetoothPairingRequestKind.pinCode,
        devicePath: '/org/bluez/hci0/dev_1',
        address: '00:11:22:33:44:55',
        deviceName: 'Keyboard',
      );
      backend.expectedPairingResponse = 'one-shot-secret';
      backend.emitPairing(request);
      expect(container.read(bluetoothProvider).pairingRequest?.id, 7);

      controller.respondToPairing(accepted: true, response: 'one-shot-secret');
      expect(backend.pairingResponses, 1);
      expect(backend.pairingResponseMatched, isTrue);
      expect(container.read(bluetoothProvider).pairingRequest, isNull);
      expect(
        container.read(bluetoothProvider).toString(),
        isNot(contains('one-shot-secret')),
      );

      backend.operationError = Exception('do not leak this detail');
      await controller.toggleConnection(
        container.read(bluetoothProvider).devices.single,
      );
      expect(
        container.read(bluetoothProvider).error,
        'Bluetooth could not complete the request',
      );
      expect(
        container.read(bluetoothProvider).error,
        isNot(contains('do not leak')),
      );
    },
  );
}

class _FakeBluetoothBackend implements BluetoothBackend {
  final StreamController<BluetoothSnapshot> _snapshots =
      StreamController<BluetoothSnapshot>.broadcast(sync: true);
  final StreamController<BluetoothPairingRequest?> _pairingRequests =
      StreamController<BluetoothPairingRequest?>.broadcast(sync: true);

  BluetoothSnapshot _current = _snapshot(powered: true);
  BluetoothPairingRequest? _pairingRequest;
  bool started = false;
  final List<bool> powerWrites = <bool>[];
  final List<bool> trustWrites = <bool>[];
  int discoveryStarts = 0;
  int discoveryStops = 0;
  int pairCalls = 0;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int removeCalls = 0;
  int pairingResponses = 0;
  String? expectedPairingResponse;
  bool pairingResponseMatched = false;
  Completer<void>? powerGate;
  Completer<void>? deviceGate;
  Object? operationError;

  @override
  BluetoothSnapshot get currentSnapshot => _current;

  @override
  BluetoothPairingRequest? get currentPairingRequest => _pairingRequest;

  @override
  Stream<BluetoothSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<BluetoothPairingRequest?> get pairingRequests =>
      _pairingRequests.stream;

  void emit(BluetoothSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  void emitPairing(BluetoothPairingRequest? request) {
    _pairingRequest = request;
    _pairingRequests.add(request);
  }

  @override
  Future<void> start() async {
    started = true;
    emit(_current);
  }

  @override
  Future<void> refresh() async => emit(_current);

  @override
  Future<void> setPowered(bool powered) async {
    powerWrites.add(powered);
    await powerGate?.future;
    _throwIfNeeded();
    emit(_snapshot(powered: powered));
  }

  @override
  Future<void> startDiscovery() async {
    discoveryStarts += 1;
    _throwIfNeeded();
    emit(_snapshot(powered: true, discovering: true));
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStops += 1;
    emit(_snapshot(powered: true));
  }

  @override
  Future<void> pair(BluetoothDeviceInfo device) async {
    pairCalls += 1;
    await deviceGate?.future;
    _throwIfNeeded();
  }

  @override
  Future<void> setTrusted(BluetoothDeviceInfo device, bool trusted) async {
    trustWrites.add(trusted);
    _throwIfNeeded();
  }

  @override
  Future<void> connect(BluetoothDeviceInfo device) async {
    connectCalls += 1;
    _throwIfNeeded();
  }

  @override
  Future<void> disconnect(BluetoothDeviceInfo device) async {
    disconnectCalls += 1;
    _throwIfNeeded();
  }

  @override
  Future<void> remove(BluetoothDeviceInfo device) async {
    removeCalls += 1;
    _throwIfNeeded();
  }

  @override
  void respondToPairing(
    int requestId, {
    required bool accepted,
    String? response,
  }) {
    pairingResponses += 1;
    pairingResponseMatched =
        accepted &&
        requestId == _pairingRequest?.id &&
        response == expectedPairingResponse;
    emitPairing(null);
  }

  void _throwIfNeeded() {
    final error = operationError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _pairingRequests.close();
  }
}

BluetoothSnapshot _snapshot({required bool powered, bool discovering = false}) {
  return BluetoothSnapshot(
    serviceAvailable: true,
    available: true,
    adapterPath: '/org/bluez/hci0',
    adapterName: 'Test adapter',
    powered: powered,
    discovering: discovering,
    pairable: true,
    devices: <BluetoothDeviceInfo>[
      BluetoothDeviceInfo(
        objectPath: '/org/bluez/hci0/dev_1',
        adapterPath: '/org/bluez/hci0',
        address: '00:11:22:33:44:55',
        name: 'Keyboard',
        icon: 'input-keyboard',
        connected: false,
        paired: false,
        trusted: false,
        blocked: false,
        servicesResolved: false,
        signalStrength: -42,
      ),
    ],
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
