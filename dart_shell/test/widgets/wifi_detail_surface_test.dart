import 'dart:async';

import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/services/network_service.dart';
import 'package:denial_dart_shell/src/state/network_connectivity.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/connectivity/wifi_detail_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('surface is truthful without a network service or adapter', (
    tester,
  ) async {
    final backend = _FakeNetworkBackend(NetworkSnapshot.unavailable());
    addTearDown(backend.dispose);
    final container = ProviderContainer.test(
      overrides: <Override>[networkServiceProvider.overrideWithValue(backend)],
    );

    await tester.pumpWidget(_host(container));
    await tester.pump();
    expect(find.text('Network service is unavailable'), findsOneWidget);

    backend.emit(_snapshot(networks: const <WifiNetwork>[], hasAdapter: false));
    await tester.pump();
    expect(find.text('No Wi-Fi adapter'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('credential is one-shot and network actions are direct', (
    tester,
  ) async {
    final backend = _FakeNetworkBackend(
      _snapshot(
        networks: <WifiNetwork>[
          _network('Secure', security: WifiSecurity.wpaPersonal),
          _network('Saved', connected: true, savedNetworkPath: '/saved/1'),
        ],
      ),
    );
    addTearDown(backend.dispose);
    final container = ProviderContainer.test(
      overrides: <Override>[networkServiceProvider.overrideWithValue(backend)],
    );

    await tester.pumpWidget(_host(container, textScale: 1.3));
    await tester.pump();
    expect(find.text('Secure'), findsOneWidget);
    expect(find.text('Saved'), findsNWidgets(2));

    await tester.tap(find.text('Secure'));
    await tester.pump();
    expect(find.byType(EditableText), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'one-shot-secret');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();

    expect(backend.connectCalls, 1);
    expect(backend.passwordMatched, isTrue);
    expect(find.byType(EditableText), findsNothing);
    expect(
      container.read(networkConnectivityProvider).toString(),
      isNot(contains('one-shot-secret')),
    );

    await tester.tap(find.bySemanticsLabel('Disconnect from Saved'));
    await tester.pump();
    expect(backend.disconnectCalls, 1);

    await tester.tap(find.bySemanticsLabel('Forget Saved'));
    await tester.pump();
    expect(backend.forgetCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(ProviderContainer container, {double textScale = 1}) {
  return UncontrolledProviderScope(
    container: container,
    child: DenialLocalizationScope(
      child: MediaQuery(
        data: MediaQueryData(
          size: const Size(600, 760),
          textScaler: TextScaler.linear(textScale),
        ),
        child: DefaultTextStyle(
          style: ShellText.base,
          child: SizedBox(
            width: 600,
            height: 760,
            child: WifiDetailSurface(onClose: _noop),
          ),
        ),
      ),
    ),
  );
}

void _noop() {}

class _FakeNetworkBackend implements NetworkBackend {
  _FakeNetworkBackend(this._current);

  final StreamController<NetworkSnapshot> _snapshots =
      StreamController<NetworkSnapshot>.broadcast(sync: true);
  NetworkSnapshot _current;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int forgetCalls = 0;
  bool passwordMatched = false;

  @override
  NetworkSnapshot get currentSnapshot => _current;

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  void emit(NetworkSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> start() async => emit(_current);

  @override
  Future<void> refresh() async => emit(_current);

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    emit(_snapshot(networks: _current.networks, enabled: enabled));
  }

  @override
  Future<void> requestScan() async {}

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    connectCalls += 1;
    passwordMatched = password == 'one-shot-secret';
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    forgetCalls += 1;
  }

  @override
  Future<void> dispose() => _snapshots.close();
}

NetworkSnapshot _snapshot({
  required List<WifiNetwork> networks,
  bool hasAdapter = true,
  bool enabled = true,
}) {
  return NetworkSnapshot(
    serviceAvailable: true,
    wifiDeviceAvailable: hasAdapter,
    wirelessHardwareEnabled: true,
    wirelessEnabled: enabled,
    status: enabled
        ? NetworkConnectivityStatus.online
        : NetworkConnectivityStatus.disabled,
    networks: networks,
    activeNetworkPath: networks.any((network) => network.connected)
        ? '/active/1'
        : null,
    devicePath: hasAdapter ? '/device/1' : null,
    lastScan: 1,
    radioPermission: NetworkPermission.allowed,
    controlPermission: NetworkPermission.allowed,
    modifyPermission: NetworkPermission.allowed,
  );
}

WifiNetwork _network(
  String ssid, {
  WifiSecurity security = WifiSecurity.open,
  bool connected = false,
  String? savedNetworkPath,
}) {
  return WifiNetwork(
    ssid: ssid,
    ssidBytes: ssid.codeUnits,
    security: security,
    strength: 72,
    frequency: 5180,
    devicePath: '/device/1',
    networkPath: '/access/$ssid',
    savedNetworkPath: savedNetworkPath,
    connected: connected,
    available: true,
  );
}
