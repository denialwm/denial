import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

enum NetworkConnectivityStatus {
  unavailable,
  disabled,
  disconnected,
  connecting,
  local,
  limited,
  captivePortal,
  online,
}

enum NetworkPermission { allowed, authenticationRequired, denied, unknown }

enum WifiSecurity {
  open,
  wep,
  wpaPersonal,
  wpa3Personal,
  owe,
  enterprise,
  unknown;

  bool get requiresPassword => switch (this) {
    WifiSecurity.wep ||
    WifiSecurity.wpaPersonal ||
    WifiSecurity.wpa3Personal => true,
    _ => false,
  };

  bool get canCreateProfile => this != enterprise && this != unknown;

  String get identityGroup => switch (this) {
    WifiSecurity.wpaPersonal || WifiSecurity.wpa3Personal => 'personal',
    _ => name,
  };

  String get label => switch (this) {
    WifiSecurity.open => 'Open',
    WifiSecurity.wep => 'WEP',
    WifiSecurity.wpaPersonal => 'WPA/WPA2 Personal',
    WifiSecurity.wpa3Personal => 'WPA3 Personal',
    WifiSecurity.owe => 'Enhanced Open',
    WifiSecurity.enterprise => 'Enterprise',
    WifiSecurity.unknown => 'Unsupported security',
  };
}

@immutable
class WifiNetwork {
  WifiNetwork({
    required this.ssid,
    required List<int> ssidBytes,
    required this.security,
    required this.strength,
    required this.frequency,
    required this.devicePath,
    required this.networkPath,
    required this.savedNetworkPath,
    required this.connected,
    required this.available,
    this.supported = true,
  }) : ssidBytes = List<int>.unmodifiable(ssidBytes),
       identity = identityFor(ssidBytes, security);

  final String identity;
  final String ssid;
  final List<int> ssidBytes;
  final WifiSecurity security;
  final int strength;
  final int frequency;
  final String devicePath;
  final String networkPath;
  final String? savedNetworkPath;
  final bool connected;
  final bool available;
  final bool supported;

  bool get saved => savedNetworkPath != null;

  bool get connectable =>
      supported &&
      devicePath.isNotEmpty &&
      (saved || (available && security.canCreateProfile));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WifiNetwork &&
          other.identity == identity &&
          other.ssid == ssid &&
          listEquals(other.ssidBytes, ssidBytes) &&
          other.security == security &&
          other.strength == strength &&
          other.frequency == frequency &&
          other.devicePath == devicePath &&
          other.networkPath == networkPath &&
          other.savedNetworkPath == savedNetworkPath &&
          other.connected == connected &&
          other.available == available &&
          other.supported == supported;

  @override
  int get hashCode => Object.hash(
    identity,
    ssid,
    Object.hashAll(ssidBytes),
    security,
    strength,
    frequency,
    devicePath,
    networkPath,
    savedNetworkPath,
    connected,
    available,
    supported,
  );

  WifiNetwork copyWith({
    String? devicePath,
    String? networkPath,
    String? savedNetworkPath,
    bool? connected,
    bool? available,
    bool? supported,
  }) {
    return WifiNetwork(
      ssid: ssid,
      ssidBytes: ssidBytes,
      security: security,
      strength: strength,
      frequency: frequency,
      devicePath: devicePath ?? this.devicePath,
      networkPath: networkPath ?? this.networkPath,
      savedNetworkPath: savedNetworkPath ?? this.savedNetworkPath,
      connected: connected ?? this.connected,
      available: available ?? this.available,
      supported: supported ?? this.supported,
    );
  }

  static String identityFor(List<int> ssidBytes, WifiSecurity security) {
    final encoded = base64Url.encode(ssidBytes).replaceAll('=', '');
    return '$encoded:${security.identityGroup}';
  }
}

@immutable
class SavedWifiConnectionInfo {
  SavedWifiConnectionInfo({
    required this.objectPath,
    required this.name,
    required List<int> ssidBytes,
    required this.security,
  }) : ssidBytes = List<int>.unmodifiable(ssidBytes),
       identity = WifiNetwork.identityFor(ssidBytes, security);

  final String objectPath;
  final String name;
  final List<int> ssidBytes;
  final WifiSecurity security;
  final String identity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedWifiConnectionInfo &&
          other.objectPath == objectPath &&
          other.name == name &&
          listEquals(other.ssidBytes, ssidBytes) &&
          other.security == security &&
          other.identity == identity;

  @override
  int get hashCode => Object.hash(
    objectPath,
    name,
    Object.hashAll(ssidBytes),
    security,
    identity,
  );
}

@immutable
class NetworkSnapshot {
  NetworkSnapshot({
    required this.serviceAvailable,
    required this.wifiDeviceAvailable,
    required this.wirelessHardwareEnabled,
    required this.wirelessEnabled,
    required this.status,
    required List<WifiNetwork> networks,
    required this.activeNetworkPath,
    required this.devicePath,
    required this.lastScan,
    required this.radioPermission,
    required this.controlPermission,
    required this.modifyPermission,
  }) : networks = List<WifiNetwork>.unmodifiable(networks);

  const NetworkSnapshot.unavailable()
    : serviceAvailable = false,
      wifiDeviceAvailable = false,
      wirelessHardwareEnabled = false,
      wirelessEnabled = false,
      status = NetworkConnectivityStatus.unavailable,
      networks = const <WifiNetwork>[],
      activeNetworkPath = null,
      devicePath = null,
      lastScan = -1,
      radioPermission = NetworkPermission.unknown,
      controlPermission = NetworkPermission.unknown,
      modifyPermission = NetworkPermission.unknown;

  final bool serviceAvailable;
  final bool wifiDeviceAvailable;
  final bool wirelessHardwareEnabled;
  final bool wirelessEnabled;
  final NetworkConnectivityStatus status;
  final List<WifiNetwork> networks;
  final String? activeNetworkPath;
  final String? devicePath;
  final int lastScan;
  final NetworkPermission radioPermission;
  final NetworkPermission controlPermission;
  final NetworkPermission modifyPermission;

  WifiNetwork? get connectedNetwork {
    for (final network in networks) {
      if (network.connected) {
        return network;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkSnapshot &&
          other.serviceAvailable == serviceAvailable &&
          other.wifiDeviceAvailable == wifiDeviceAvailable &&
          other.wirelessHardwareEnabled == wirelessHardwareEnabled &&
          other.wirelessEnabled == wirelessEnabled &&
          other.status == status &&
          listEquals(other.networks, networks) &&
          other.activeNetworkPath == activeNetworkPath &&
          other.devicePath == devicePath &&
          other.lastScan == lastScan &&
          other.radioPermission == radioPermission &&
          other.controlPermission == controlPermission &&
          other.modifyPermission == modifyPermission;

  @override
  int get hashCode => Object.hash(
    serviceAvailable,
    wifiDeviceAvailable,
    wirelessHardwareEnabled,
    wirelessEnabled,
    status,
    Object.hashAll(networks),
    activeNetworkPath,
    devicePath,
    lastScan,
    radioPermission,
    controlPermission,
    modifyPermission,
  );
}

abstract interface class NetworkBackend {
  Stream<NetworkSnapshot> get snapshots;

  NetworkSnapshot get currentSnapshot;

  Future<void> start();

  Future<void> refresh();

  Future<void> setWirelessEnabled(bool enabled);

  Future<void> requestScan();

  Future<void> connect(WifiNetwork network, {String? password});

  Future<void> disconnect();

  Future<void> forget(WifiNetwork network);

  Future<void> dispose();
}

List<WifiNetwork> normalizeWifiNetworks(
  Iterable<WifiNetwork> candidates,
  Iterable<SavedWifiConnectionInfo> savedConnections, {
  required String defaultDevicePath,
  int maximum = 64,
}) {
  final visible = <String, WifiNetwork>{};
  for (final candidate in candidates) {
    final current = visible[candidate.identity];
    if (current == null ||
        (!current.connected && candidate.connected) ||
        (current.connected == candidate.connected &&
            candidate.strength > current.strength)) {
      visible[candidate.identity] = candidate;
    }
  }

  final savedByIdentity = <String, SavedWifiConnectionInfo>{};
  for (final saved in savedConnections) {
    savedByIdentity.putIfAbsent(saved.identity, () => saved);
  }
  for (final entry in visible.entries.toList(growable: false)) {
    final saved = savedByIdentity.remove(entry.key);
    if (saved != null) {
      visible[entry.key] = entry.value.copyWith(
        savedNetworkPath: saved.objectPath,
      );
    }
  }
  for (final saved in savedByIdentity.values) {
    visible[saved.identity] = WifiNetwork(
      ssid: saved.name,
      ssidBytes: saved.ssidBytes,
      security: saved.security,
      strength: 0,
      frequency: 0,
      devicePath: defaultDevicePath,
      networkPath: '/',
      savedNetworkPath: saved.objectPath,
      connected: false,
      available: false,
    );
  }

  final networks = visible.values.toList(growable: false)
    ..sort((left, right) {
      var result = _trueFirst(left.connected, right.connected);
      if (result != 0) {
        return result;
      }
      result = _trueFirst(left.saved, right.saved);
      if (result != 0) {
        return result;
      }
      result = _trueFirst(left.available, right.available);
      if (result != 0) {
        return result;
      }
      result = right.strength.compareTo(left.strength);
      return result != 0
          ? result
          : left.ssid.toLowerCase().compareTo(right.ssid.toLowerCase());
    });
  return List<WifiNetwork>.unmodifiable(networks.take(maximum));
}

int _trueFirst(bool left, bool right) {
  if (left == right) {
    return 0;
  }
  return left ? -1 : 1;
}
