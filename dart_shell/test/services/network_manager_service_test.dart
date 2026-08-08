import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/network_manager_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('security and connectivity classification is explicit', () {
    expect(
      classifyWifiSecurity(flags: 0, wpaFlags: 0, rsnFlags: 0),
      WifiSecurity.open,
    );
    expect(
      classifyWifiSecurity(flags: 1, wpaFlags: 0, rsnFlags: 0),
      WifiSecurity.wep,
    );
    expect(
      classifyWifiSecurity(flags: 1, wpaFlags: 0x100, rsnFlags: 0),
      WifiSecurity.wpaPersonal,
    );
    expect(
      classifyWifiSecurity(flags: 1, wpaFlags: 0, rsnFlags: 0x400),
      WifiSecurity.wpa3Personal,
    );
    expect(
      classifyWifiSecurity(flags: 1, wpaFlags: 0, rsnFlags: 0x200),
      WifiSecurity.enterprise,
    );
    expect(
      classifyWifiSecurity(flags: 1, wpaFlags: 0, rsnFlags: 0x800),
      WifiSecurity.owe,
    );

    expect(
      classifyNetworkConnectivity(
        hardwareEnabled: true,
        wirelessEnabled: true,
        managerState: 40,
        connectivity: 0,
        deviceState: 50,
      ),
      NetworkConnectivityStatus.connecting,
    );
    expect(
      classifyNetworkConnectivity(
        hardwareEnabled: true,
        wirelessEnabled: true,
        managerState: 70,
        connectivity: 2,
        deviceState: 100,
      ),
      NetworkConnectivityStatus.captivePortal,
    );
    expect(
      classifyNetworkConnectivity(
        hardwareEnabled: true,
        wirelessEnabled: true,
        managerState: 70,
        connectivity: 4,
        deviceState: 100,
      ),
      NetworkConnectivityStatus.online,
    );
  });

  test('access points deduplicate, merge saved profiles, sort, and bound', () {
    final candidates = <WifiNetwork>[
      _network('Cafe', strength: 25),
      _network('Cafe', strength: 82),
      _network(
        'Home',
        strength: 65,
        security: WifiSecurity.wpa3Personal,
        connected: true,
      ),
      for (var index = 0; index < 80; index += 1)
        _network('Network $index', strength: index),
    ];
    final saved = <SavedWifiConnectionInfo>[
      SavedWifiConnectionInfo(
        objectPath: '/saved/home',
        name: 'Home',
        ssidBytes: 'Home'.codeUnits,
        security: WifiSecurity.wpaPersonal,
      ),
      SavedWifiConnectionInfo(
        objectPath: '/saved/away',
        name: 'Away',
        ssidBytes: 'Away'.codeUnits,
        security: WifiSecurity.wpaPersonal,
      ),
    ];

    final normalized = normalizeWifiNetworks(
      candidates,
      saved,
      defaultDevicePath: '/device/1',
    );

    expect(normalized, hasLength(64));
    expect(normalized.first.ssid, 'Home');
    expect(normalized.first.savedConnectionPath, '/saved/home');
    expect(normalized.where((network) => network.ssid == 'Cafe'), hasLength(1));
    expect(
      normalized.singleWhere((network) => network.ssid == 'Cafe').strength,
      82,
    );
    final away = normalized.singleWhere((network) => network.ssid == 'Away');
    expect(away.saved, isTrue);
    expect(away.available, isFalse);
  });

  test('new profiles encode bounded supported security settings', () {
    final network = _network(
      'Home',
      strength: 90,
      security: WifiSecurity.wpaPersonal,
    );
    final settings = buildWifiConnectionSettings(
      network,
      password: 'correct horse',
    );
    final sections = <String, Map<String, DBusValue>>{
      for (final entry in settings.asDict().entries)
        entry.key.asString(): entry.value.asStringVariantDict(),
    };

    expect(
      (sections['connection']!['type']! as DBusString).value,
      '802-11-wireless',
    );
    expect(
      sections['802-11-wireless']!['ssid']!.asByteArray(),
      'Home'.codeUnits,
    );
    expect(
      (sections['802-11-wireless-security']!['key-mgmt']! as DBusString).value,
      'wpa-psk',
    );
    expect(
      () => buildWifiConnectionSettings(network, password: 'short'),
      throwsArgumentError,
    );
    expect(
      () => buildWifiConnectionSettings(
        _network('Company', strength: 60, security: WifiSecurity.enterprise),
      ),
      throwsStateError,
    );
  });
}

WifiNetwork _network(
  String ssid, {
  required int strength,
  WifiSecurity security = WifiSecurity.open,
  bool connected = false,
}) {
  return WifiNetwork(
    ssid: ssid,
    ssidBytes: ssid.codeUnits,
    security: security,
    strength: strength,
    frequency: 5180,
    devicePath: '/device/1',
    accessPointPath: '/access/${ssid.hashCode}/$strength',
    savedConnectionPath: null,
    connected: connected,
    available: true,
  );
}
