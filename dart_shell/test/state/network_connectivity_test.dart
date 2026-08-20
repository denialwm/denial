import 'dart:async';

import 'package:denial_dart_shell/src/services/network_service.dart';
import 'package:denial_dart_shell/src/state/network_connectivity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'controller follows service signals and serializes user operations',
    () async {
      final service = _FakeNetworkBackend();
      addTearDown(service.dispose);
      final container = ProviderContainer.test(
        overrides: [networkServiceProvider.overrideWithValue(service)],
      );
      final controller = container.read(networkConnectivityProvider.notifier);
      await _settle();

      expect(service.started, isTrue);
      expect(
        container.read(networkConnectivityProvider).snapshot.wirelessEnabled,
        isFalse,
      );

      await controller.toggleWireless();
      expect(service.radioWrites, <bool>[true]);
      expect(
        container.read(networkConnectivityProvider).snapshot.wirelessEnabled,
        isTrue,
      );

      await controller.scan();
      expect(container.read(networkConnectivityProvider).scanning, isTrue);
      service.emit(_snapshot(enabled: true, lastScan: 12));
      expect(container.read(networkConnectivityProvider).scanning, isFalse);

      final network = container
          .read(networkConnectivityProvider)
          .snapshot
          .networks
          .single;
      service.connectGate = Completer<void>();
      final first = controller.connect(network, password: 'never-store-me');
      final duplicate = controller.connect(network, password: 'never-store-me');
      expect(service.connectCalls, 1);
      expect(service.passwordWasProvided, isTrue);
      expect(container.read(networkConnectivityProvider).busyNetworks, <String>{
        network.identity,
      });
      service.connectGate!.complete();
      await Future.wait(<Future<void>>[first, duplicate]);
      expect(container.read(networkConnectivityProvider).busyNetworks, isEmpty);

      service.operationError = Exception('secret should never be echoed');
      await controller.disconnect(network);
      expect(
        container.read(networkConnectivityProvider).error,
        'The network service could not complete the request',
      );
      expect(
        container.read(networkConnectivityProvider).error,
        isNot(contains('secret')),
      );
    },
  );

  test('service loss is reflected without reopening the surface', () async {
    final service = _FakeNetworkBackend();
    addTearDown(service.dispose);
    final container = ProviderContainer.test(
      overrides: [networkServiceProvider.overrideWithValue(service)],
    );
    container.read(networkConnectivityProvider.notifier);
    await _settle();

    service.emit(NetworkSnapshot.unavailable());
    expect(
      container.read(networkConnectivityProvider).snapshot.serviceAvailable,
      isFalse,
    );
    expect(container.read(networkConnectivityProvider).initializing, isFalse);
  });

  test(
    'denied permissions prevent actions before D-Bus receives them',
    () async {
      final service = _FakeNetworkBackend();
      addTearDown(service.dispose);
      final container = ProviderContainer.test(
        overrides: [networkServiceProvider.overrideWithValue(service)],
      );
      final controller = container.read(networkConnectivityProvider.notifier);
      await _settle();

      service.emit(
        _snapshot(
          enabled: true,
          lastScan: 2,
          controlPermission: NetworkPermission.denied,
          modifyPermission: NetworkPermission.denied,
        ),
      );
      final network = container
          .read(networkConnectivityProvider)
          .snapshot
          .networks
          .single;
      await controller.connect(network, password: 'must-not-cross-boundary');
      await controller.disconnect(network);
      await controller.scan();

      expect(service.connectCalls, 0);
      expect(service.passwordWasProvided, isFalse);
      expect(container.read(networkConnectivityProvider).scanning, isFalse);
      expect(
        container.read(networkConnectivityProvider).error,
        'Wi-Fi changes are not permitted',
      );
    },
  );
}

class _FakeNetworkBackend implements NetworkBackend {
  final StreamController<NetworkSnapshot> _snapshots =
      StreamController<NetworkSnapshot>.broadcast(sync: true);

  NetworkSnapshot _current = _snapshot(enabled: false, lastScan: 1);
  bool started = false;
  final List<bool> radioWrites = <bool>[];
  int connectCalls = 0;
  bool passwordWasProvided = false;
  Completer<void>? connectGate;
  Object? operationError;

  @override
  NetworkSnapshot get currentSnapshot => _current;

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  void emit(NetworkSnapshot snapshot) {
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

NetworkSnapshot _snapshot({
  required bool enabled,
  required int lastScan,
  NetworkPermission controlPermission = NetworkPermission.allowed,
  NetworkPermission modifyPermission = NetworkPermission.allowed,
}) {
  return NetworkSnapshot(
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
        networkPath: '/access/1',
        savedNetworkPath: null,
        connected: false,
        available: true,
      ),
    ],
    activeNetworkPath: null,
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
