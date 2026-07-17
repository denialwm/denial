import 'dart:async';

import 'package:denial_dart_shell/src/services/network_manager_service.dart';
import 'package:denial_dart_shell/src/state/network_connectivity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('controller follows service signals and serializes user operations',
      () async {
    final service = _FakeNetworkManager();
    final controller = NetworkConnectivityController(service);
    addTearDown(() async {
      controller.dispose();
      await service.dispose();
    });
    await _settle();

    expect(service.started, isTrue);
    expect(controller.state.snapshot.wirelessEnabled, isFalse);

    await controller.toggleWireless();
    expect(service.radioWrites, <bool>[true]);
    expect(controller.state.snapshot.wirelessEnabled, isTrue);

    await controller.scan();
    expect(controller.state.scanning, isTrue);
    service.emit(_snapshot(enabled: true, lastScan: 12));
    expect(controller.state.scanning, isFalse);

    final network = controller.state.snapshot.networks.single;
    service.connectGate = Completer<void>();
    final first = controller.connect(network, password: 'never-store-me');
    final duplicate = controller.connect(network, password: 'never-store-me');
    expect(service.connectCalls, 1);
    expect(service.passwordWasProvided, isTrue);
    expect(controller.state.busyNetworks, <String>{network.identity});
    service.connectGate!.complete();
    await Future.wait(<Future<void>>[first, duplicate]);
    expect(controller.state.busyNetworks, isEmpty);

    service.operationError = Exception('secret should never be echoed');
    await controller.disconnect(network);
    expect(controller.state.error,
        'NetworkManager could not complete the request');
    expect(controller.state.error, isNot(contains('secret')));
  });

  test('service loss is reflected without reopening the surface', () async {
    final service = _FakeNetworkManager();
    final controller = NetworkConnectivityController(service);
    addTearDown(() async {
      controller.dispose();
      await service.dispose();
    });
    await _settle();

    service.emit(NetworkManagerSnapshot.unavailable());
    expect(controller.state.snapshot.serviceAvailable, isFalse);
    expect(controller.state.initializing, isFalse);
  });

  test('denied permissions prevent actions before D-Bus receives them',
      () async {
    final service = _FakeNetworkManager();
    final controller = NetworkConnectivityController(service);
    addTearDown(() async {
      controller.dispose();
      await service.dispose();
    });
    await _settle();

    service.emit(
      _snapshot(
        enabled: true,
        lastScan: 2,
        controlPermission: NetworkPermission.denied,
        modifyPermission: NetworkPermission.denied,
      ),
    );
    final network = controller.state.snapshot.networks.single;
    await controller.connect(network, password: 'must-not-cross-boundary');
    await controller.disconnect(network);
    await controller.scan();

    expect(service.connectCalls, 0);
    expect(service.passwordWasProvided, isFalse);
    expect(controller.state.scanning, isFalse);
    expect(controller.state.error, 'Wi-Fi changes are not permitted');
  });
}

class _FakeNetworkManager implements NetworkManagerBackend {
  final StreamController<NetworkManagerSnapshot> _snapshots =
      StreamController<NetworkManagerSnapshot>.broadcast(sync: true);

  NetworkManagerSnapshot _current = _snapshot(enabled: false, lastScan: 1);
  bool started = false;
  final List<bool> radioWrites = <bool>[];
  int connectCalls = 0;
  bool passwordWasProvided = false;
  Completer<void>? connectGate;
  Object? operationError;

  @override
  NetworkManagerSnapshot get currentSnapshot => _current;

  @override
  Stream<NetworkManagerSnapshot> get snapshots => _snapshots.stream;

  void emit(NetworkManagerSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> start() async {
    started = true;
    emit(_current);
  }

  @override
  Future<void> refresh() async => emit(_current);

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    radioWrites.add(enabled);
    emit(_snapshot(enabled: enabled, lastScan: _current.lastScan));
  }

  @override
  Future<void> requestScan() async {}

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    connectCalls += 1;
    passwordWasProvided = password != null;
    await connectGate?.future;
    _throwIfNeeded();
  }

  @override
  Future<void> disconnect() async => _throwIfNeeded();

  @override
  Future<void> forget(WifiNetwork network) async => _throwIfNeeded();

  void _throwIfNeeded() {
    final error = operationError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> dispose() => _snapshots.close();
}

NetworkManagerSnapshot _snapshot({
  required bool enabled,
  required int lastScan,
  NetworkPermission controlPermission = NetworkPermission.allowed,
  NetworkPermission modifyPermission = NetworkPermission.allowed,
}) {
  return NetworkManagerSnapshot(
    serviceAvailable: true,
    wifiDeviceAvailable: true,
    wirelessHardwareEnabled: true,
    wirelessEnabled: enabled,
    status: enabled
        ? NetworkConnectivityStatus.disconnected
        : NetworkConnectivityStatus.disabled,
    networks: <WifiNetwork>[
      WifiNetwork(
        ssid: 'Test network',
        ssidBytes: 'Test network'.codeUnits,
        security: WifiSecurity.wpaPersonal,
        strength: 75,
        frequency: 5180,
        devicePath: '/device/1',
        accessPointPath: '/access/1',
        savedConnectionPath: null,
        connected: false,
        available: true,
      ),
    ],
    activeConnectionPath: null,
    devicePath: '/device/1',
    lastScan: lastScan,
    radioPermission: NetworkPermission.allowed,
    controlPermission: controlPermission,
    modifyPermission: modifyPermission,
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
