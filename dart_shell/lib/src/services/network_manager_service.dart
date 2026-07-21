import 'dart:async';
import 'dart:convert';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final networkManagerServiceProvider = Provider<NetworkManagerBackend>((ref) {
  final service = NetworkManagerService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

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
    required this.accessPointPath,
    required this.savedConnectionPath,
    required this.connected,
    required this.available,
  }) : ssidBytes = List<int>.unmodifiable(ssidBytes),
       identity = identityFor(ssidBytes, security);

  final String identity;
  final String ssid;
  final List<int> ssidBytes;
  final WifiSecurity security;
  final int strength;
  final int frequency;
  final String devicePath;
  final String accessPointPath;
  final String? savedConnectionPath;
  final bool connected;
  final bool available;

  bool get saved => savedConnectionPath != null;

  bool get connectable =>
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
          other.accessPointPath == accessPointPath &&
          other.savedConnectionPath == savedConnectionPath &&
          other.connected == connected &&
          other.available == available;

  @override
  int get hashCode => Object.hash(
    identity,
    ssid,
    Object.hashAll(ssidBytes),
    security,
    strength,
    frequency,
    devicePath,
    accessPointPath,
    savedConnectionPath,
    connected,
    available,
  );

  WifiNetwork copyWith({
    String? devicePath,
    String? accessPointPath,
    String? savedConnectionPath,
    bool? connected,
    bool? available,
  }) {
    return WifiNetwork(
      ssid: ssid,
      ssidBytes: ssidBytes,
      security: security,
      strength: strength,
      frequency: frequency,
      devicePath: devicePath ?? this.devicePath,
      accessPointPath: accessPointPath ?? this.accessPointPath,
      savedConnectionPath: savedConnectionPath ?? this.savedConnectionPath,
      connected: connected ?? this.connected,
      available: available ?? this.available,
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
class NetworkManagerSnapshot {
  NetworkManagerSnapshot({
    required this.serviceAvailable,
    required this.wifiDeviceAvailable,
    required this.wirelessHardwareEnabled,
    required this.wirelessEnabled,
    required this.status,
    required List<WifiNetwork> networks,
    required this.activeConnectionPath,
    required this.devicePath,
    required this.lastScan,
    required this.radioPermission,
    required this.controlPermission,
    required this.modifyPermission,
  }) : networks = List<WifiNetwork>.unmodifiable(networks);

  const NetworkManagerSnapshot.unavailable()
    : serviceAvailable = false,
      wifiDeviceAvailable = false,
      wirelessHardwareEnabled = false,
      wirelessEnabled = false,
      status = NetworkConnectivityStatus.unavailable,
      networks = const <WifiNetwork>[],
      activeConnectionPath = null,
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
  final String? activeConnectionPath;
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
      other is NetworkManagerSnapshot &&
          other.serviceAvailable == serviceAvailable &&
          other.wifiDeviceAvailable == wifiDeviceAvailable &&
          other.wirelessHardwareEnabled == wirelessHardwareEnabled &&
          other.wirelessEnabled == wirelessEnabled &&
          other.status == status &&
          listEquals(other.networks, networks) &&
          other.activeConnectionPath == activeConnectionPath &&
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
    activeConnectionPath,
    devicePath,
    lastScan,
    radioPermission,
    controlPermission,
    modifyPermission,
  );
}

abstract interface class NetworkManagerBackend {
  Stream<NetworkManagerSnapshot> get snapshots;

  NetworkManagerSnapshot get currentSnapshot;

  Future<void> start();

  Future<void> refresh();

  Future<void> setWirelessEnabled(bool enabled);

  Future<void> requestScan();

  Future<void> connect(WifiNetwork network, {String? password});

  Future<void> disconnect();

  Future<void> forget(WifiNetwork network);

  Future<void> dispose();
}

class NetworkManagerService implements NetworkManagerBackend {
  factory NetworkManagerService({DBusClient? client}) {
    return NetworkManagerService._(client ?? DBusClient.system());
  }

  NetworkManagerService._(this._client)
    : _root = DBusRemoteObject(
        _client,
        name: _serviceName,
        path: DBusObjectPath(_rootPath),
      ),
      _settings = DBusRemoteObject(
        _client,
        name: _serviceName,
        path: DBusObjectPath(_settingsPath),
      );

  static const String _serviceName = 'org.freedesktop.NetworkManager';
  static const String _rootPath = '/org/freedesktop/NetworkManager';
  static const String _settingsPath = '$_rootPath/Settings';
  static const String _managerInterface = 'org.freedesktop.NetworkManager';
  static const String _deviceInterface =
      'org.freedesktop.NetworkManager.Device';
  static const String _wirelessInterface =
      'org.freedesktop.NetworkManager.Device.Wireless';
  static const String _accessPointInterface =
      'org.freedesktop.NetworkManager.AccessPoint';
  static const String _settingsInterface =
      'org.freedesktop.NetworkManager.Settings';
  static const String _settingsConnectionInterface =
      'org.freedesktop.NetworkManager.Settings.Connection';

  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _methodTimeout = Duration(seconds: 25);
  static const Duration _signalCoalesce = Duration(milliseconds: 55);
  static const int _maxDevices = 16;
  static const int _maxAccessPoints = 128;
  static const int _maxSavedConnections = 128;
  static const int _readBatchSize = 12;

  final DBusClient _client;
  final DBusRemoteObject _root;
  final DBusRemoteObject _settings;
  final StreamController<NetworkManagerSnapshot> _snapshots =
      StreamController<NetworkManagerSnapshot>.broadcast(sync: true);

  StreamSubscription<DBusSignal>? _signalSubscription;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerSubscription;
  Timer? _refreshTimer;
  bool _started = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  NetworkManagerSnapshot _current = NetworkManagerSnapshot.unavailable();

  @override
  Stream<NetworkManagerSnapshot> get snapshots => _snapshots.stream;

  @override
  NetworkManagerSnapshot get currentSnapshot => _current;

  @override
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _signalSubscription = DBusSignalStream(
      _client,
      sender: _serviceName,
      pathNamespace: DBusObjectPath(_rootPath),
    ).listen((_) => _scheduleRefresh(), onError: (_) => _scheduleRefresh());
    _ownerSubscription = _client.nameOwnerChanged
        .where((event) => event.name == _serviceName)
        .listen((event) {
          if (event.newOwner == null) {
            _refreshTimer?.cancel();
            _emit(NetworkManagerSnapshot.unavailable());
          } else {
            _scheduleRefresh(immediate: true);
          }
        });
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      final snapshot = await _readSnapshot();
      if (!_disposed) {
        _emit(snapshot);
      }
    } on Object {
      if (!_disposed) {
        _emit(NetworkManagerSnapshot.unavailable());
      }
    } finally {
      _refreshing = false;
      if (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        _scheduleRefresh(immediate: true);
      }
    }
  }

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    await _root
        .setProperty(_managerInterface, 'WirelessEnabled', DBusBoolean(enabled))
        .timeout(_methodTimeout);
    await refresh();
  }

  @override
  Future<void> requestScan() async {
    final devicePath = _current.devicePath;
    if (devicePath == null) {
      throw StateError('No Wi-Fi adapter is available');
    }
    await _object(devicePath)
        .callMethod(_wirelessInterface, 'RequestScan', <DBusValue>[
          DBusDict.stringVariant(const <String, DBusValue>{}),
        ], replySignature: DBusSignature(''))
        .timeout(_methodTimeout);
  }

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    if (!network.connectable) {
      throw StateError('This Wi-Fi network cannot be connected');
    }
    final device = DBusObjectPath(network.devicePath);
    final accessPoint = DBusObjectPath(
      network.accessPointPath.isEmpty ? '/' : network.accessPointPath,
    );
    final saved = network.savedConnectionPath;
    if (saved != null) {
      await _root
          .callMethod(
            _managerInterface,
            'ActivateConnection',
            <DBusValue>[DBusObjectPath(saved), device, accessPoint],
            replySignature: DBusSignature('o'),
          )
          .timeout(_methodTimeout);
      return;
    }

    final settings = buildWifiConnectionSettings(network, password: password);
    await _root
        .callMethod(
          _managerInterface,
          'AddAndActivateConnection2',
          <DBusValue>[
            settings,
            device,
            accessPoint,
            DBusDict.stringVariant(const <String, DBusValue>{}),
          ],
          replySignature: DBusSignature('ooa{sv}'),
        )
        .timeout(_methodTimeout);
  }

  @override
  Future<void> disconnect() async {
    final activeConnection = _current.activeConnectionPath;
    if (activeConnection == null || activeConnection == '/') {
      return;
    }
    await _root
        .callMethod(
          _managerInterface,
          'DeactivateConnection',
          <DBusValue>[DBusObjectPath(activeConnection)],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    final path = network.savedConnectionPath;
    if (path == null) {
      return;
    }
    if (network.connected) {
      await disconnect();
    }
    await _object(path)
        .callMethod(
          _settingsConnectionInterface,
          'Delete',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
  }

  Future<NetworkManagerSnapshot> _readSnapshot() async {
    if (!await _client.nameHasOwner(_serviceName).timeout(_readTimeout)) {
      return NetworkManagerSnapshot.unavailable();
    }

    final rootProperties = await _root
        .getAllProperties(_managerInterface)
        .timeout(_readTimeout);
    final permissions = await _readPermissions();
    final deviceReply = await _root
        .callMethod(
          _managerInterface,
          'GetDevices',
          const <DBusValue>[],
          replySignature: DBusSignature('ao'),
        )
        .timeout(_readTimeout);
    final devicePaths = deviceReply.returnValues.first
        .asObjectPathArray()
        .take(_maxDevices)
        .toList(growable: false);
    final deviceSnapshots = await _mapInBatches(devicePaths, _readBatchSize, (
      path,
    ) async {
      final deviceProperties = await _tryGetAll(path.value, _deviceInterface);
      if (_uint32(deviceProperties, 'DeviceType') != 2) {
        return null;
      }
      final wirelessProperties = await _tryGetAll(
        path.value,
        _wirelessInterface,
      );
      return _WifiDeviceSnapshot(
        path: path.value,
        state: _uint32(deviceProperties, 'State'),
        activeConnectionPath: _objectPath(deviceProperties, 'ActiveConnection'),
        activeAccessPointPath: _objectPath(
          wirelessProperties,
          'ActiveAccessPoint',
        ),
        accessPoints: _objectPaths(wirelessProperties, 'AccessPoints'),
        lastScan: _int64(wirelessProperties, 'LastScan', fallback: -1),
      );
    });
    final wifiDevices = deviceSnapshots
        .whereType<_WifiDeviceSnapshot>()
        .toList();

    final wirelessEnabled = _boolean(rootProperties, 'WirelessEnabled');
    final hardwareEnabled = _boolean(rootProperties, 'WirelessHardwareEnabled');
    if (wifiDevices.isEmpty) {
      return NetworkManagerSnapshot(
        serviceAvailable: true,
        wifiDeviceAvailable: false,
        wirelessHardwareEnabled: hardwareEnabled,
        wirelessEnabled: wirelessEnabled,
        status: NetworkConnectivityStatus.unavailable,
        networks: const <WifiNetwork>[],
        activeConnectionPath: null,
        devicePath: null,
        lastScan: -1,
        radioPermission: permissions.radio,
        controlPermission: permissions.control,
        modifyPermission: permissions.modify,
      );
    }

    wifiDevices.sort((left, right) {
      final leftActive = left.activeConnectionPath != null ? 1 : 0;
      final rightActive = right.activeConnectionPath != null ? 1 : 0;
      return rightActive.compareTo(leftActive);
    });
    final primaryDevice = wifiDevices.first;
    final accessPointPaths = <String>[];
    for (final device in wifiDevices) {
      for (final path in device.accessPoints) {
        if (accessPointPaths.length == _maxAccessPoints) {
          break;
        }
        if (!accessPointPaths.contains(path)) {
          accessPointPaths.add(path);
        }
      }
    }

    final candidates = (await _mapInBatches(accessPointPaths, _readBatchSize, (
      path,
    ) async {
      final properties = await _tryGetAll(path, _accessPointInterface);
      final ssidBytes = _bytes(properties, 'Ssid');
      if (ssidBytes.isEmpty || ssidBytes.length > 32) {
        return null;
      }
      final device = wifiDevices.firstWhere(
        (candidate) => candidate.accessPoints.contains(path),
        orElse: () => primaryDevice,
      );
      final security = classifyWifiSecurity(
        flags: _uint32(properties, 'Flags'),
        wpaFlags: _uint32(properties, 'WpaFlags'),
        rsnFlags: _uint32(properties, 'RsnFlags'),
      );
      return WifiNetwork(
        ssid: utf8.decode(ssidBytes, allowMalformed: true),
        ssidBytes: ssidBytes,
        security: security,
        strength: _byte(properties, 'Strength'),
        frequency: _uint32(properties, 'Frequency'),
        devicePath: device.path,
        accessPointPath: path,
        savedConnectionPath: null,
        connected: device.activeAccessPointPath == path,
        available: true,
      );
    })).whereType<WifiNetwork>().toList(growable: false);

    final savedConnections = await _readSavedConnections();
    final networks = normalizeWifiNetworks(
      candidates,
      savedConnections,
      defaultDevicePath: primaryDevice.path,
    );
    final activeConnection = wifiDevices
        .map((device) => device.activeConnectionPath)
        .whereType<String>()
        .firstOrNull;
    final deviceState = wifiDevices
        .map((device) => device.state)
        .fold<int>(0, (current, value) => value > current ? value : current);
    final managerState = _uint32(rootProperties, 'State');
    final connectivity = _uint32(rootProperties, 'Connectivity');
    final lastScan = wifiDevices
        .map((device) => device.lastScan)
        .fold<int>(-1, (current, value) => value > current ? value : current);

    return NetworkManagerSnapshot(
      serviceAvailable: true,
      wifiDeviceAvailable: true,
      wirelessHardwareEnabled: hardwareEnabled,
      wirelessEnabled: wirelessEnabled,
      status: classifyNetworkConnectivity(
        hardwareEnabled: hardwareEnabled,
        wirelessEnabled: wirelessEnabled,
        managerState: managerState,
        connectivity: connectivity,
        deviceState: deviceState,
      ),
      networks: networks,
      activeConnectionPath: activeConnection,
      devicePath: primaryDevice.path,
      lastScan: lastScan,
      radioPermission: permissions.radio,
      controlPermission: permissions.control,
      modifyPermission: permissions.modify,
    );
  }

  Future<_NetworkPermissions> _readPermissions() async {
    try {
      final reply = await _root
          .callMethod(
            _managerInterface,
            'GetPermissions',
            const <DBusValue>[],
            replySignature: DBusSignature('a{ss}'),
          )
          .timeout(_readTimeout);
      final values = <String, String>{};
      for (final entry in reply.returnValues.first.asDict().entries) {
        values[entry.key.asString()] = entry.value.asString();
      }
      return _NetworkPermissions(
        radio: _permission(
          values['org.freedesktop.NetworkManager.enable-disable-wifi'],
        ),
        control: _permission(
          values['org.freedesktop.NetworkManager.network-control'],
        ),
        modify: _strongestPermission(
          _permission(
            values['org.freedesktop.NetworkManager.settings.modify.own'],
          ),
          _permission(
            values['org.freedesktop.NetworkManager.settings.modify.system'],
          ),
        ),
      );
    } on Object {
      return const _NetworkPermissions();
    }
  }

  Future<List<SavedWifiConnectionInfo>> _readSavedConnections() async {
    try {
      final reply = await _settings
          .callMethod(
            _settingsInterface,
            'ListConnections',
            const <DBusValue>[],
            replySignature: DBusSignature('ao'),
          )
          .timeout(_readTimeout);
      final paths = reply.returnValues.first.asObjectPathArray().take(
        _maxSavedConnections,
      );
      final saved = await _mapInBatches(paths, _readBatchSize, (path) async {
        try {
          final settingsReply = await _object(path.value)
              .callMethod(
                _settingsConnectionInterface,
                'GetSettings',
                const <DBusValue>[],
                replySignature: DBusSignature('a{sa{sv}}'),
              )
              .timeout(_readTimeout);
          final settings = _settingsMap(settingsReply.returnValues.first);
          final connection = settings['connection'];
          final wireless = settings['802-11-wireless'];
          if (_string(connection, 'type') != '802-11-wireless' ||
              wireless == null) {
            return null;
          }
          final ssid = _bytes(wireless, 'ssid');
          if (ssid.isEmpty || ssid.length > 32) {
            return null;
          }
          return SavedWifiConnectionInfo(
            objectPath: path.value,
            name: _string(
              connection,
              'id',
              fallback: utf8.decode(ssid, allowMalformed: true),
            ),
            ssidBytes: ssid,
            security: _savedSecurity(settings),
          );
        } on Object {
          return null;
        }
      });
      return List<SavedWifiConnectionInfo>.unmodifiable(
        saved.whereType<SavedWifiConnectionInfo>(),
      );
    } on Object {
      return const <SavedWifiConnectionInfo>[];
    }
  }

  Future<Map<String, DBusValue>> _tryGetAll(
    String path,
    String interface,
  ) async {
    try {
      return await _object(
        path,
      ).getAllProperties(interface).timeout(_readTimeout);
    } on Object {
      return const <String, DBusValue>{};
    }
  }

  DBusRemoteObject _object(String path) =>
      DBusRemoteObject(_client, name: _serviceName, path: DBusObjectPath(path));

  void _scheduleRefresh({bool immediate = false}) {
    if (_disposed) {
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer(immediate ? Duration.zero : _signalCoalesce, () {
      _refreshTimer = null;
      unawaited(refresh());
    });
  }

  void _emit(NetworkManagerSnapshot snapshot) {
    if (snapshot == _current) {
      return;
    }
    _current = snapshot;
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _refreshTimer?.cancel();
    await _signalSubscription?.cancel();
    await _ownerSubscription?.cancel();
    await _snapshots.close();
    await _client.close();
  }
}

Future<List<R>> _mapInBatches<T, R>(
  Iterable<T> values,
  int batchSize,
  Future<R> Function(T value) transform,
) async {
  final pending = values.toList(growable: false);
  final result = <R>[];
  for (var offset = 0; offset < pending.length; offset += batchSize) {
    final end = (offset + batchSize).clamp(0, pending.length).toInt();
    result.addAll(
      await Future.wait<R>(pending.sublist(offset, end).map(transform)),
    );
  }
  return result;
}

@visibleForTesting
WifiSecurity classifyWifiSecurity({
  required int flags,
  required int wpaFlags,
  required int rsnFlags,
}) {
  final securityFlags = wpaFlags | rsnFlags;
  if (securityFlags & 0x400 != 0) {
    return WifiSecurity.wpa3Personal;
  }
  if (securityFlags & 0x100 != 0) {
    return WifiSecurity.wpaPersonal;
  }
  if (securityFlags & (0x200 | 0x2000) != 0) {
    return WifiSecurity.enterprise;
  }
  if (securityFlags & (0x800 | 0x1000) != 0) {
    return WifiSecurity.owe;
  }
  if (securityFlags != 0) {
    return WifiSecurity.unknown;
  }
  if (flags & 0x1 != 0) {
    return WifiSecurity.wep;
  }
  return WifiSecurity.open;
}

@visibleForTesting
NetworkConnectivityStatus classifyNetworkConnectivity({
  required bool hardwareEnabled,
  required bool wirelessEnabled,
  required int managerState,
  required int connectivity,
  required int deviceState,
}) {
  if (!hardwareEnabled || !wirelessEnabled || managerState == 10) {
    return NetworkConnectivityStatus.disabled;
  }
  if (managerState == 40 || (deviceState >= 40 && deviceState <= 90)) {
    return NetworkConnectivityStatus.connecting;
  }
  return switch (connectivity) {
    4 => NetworkConnectivityStatus.online,
    3 => NetworkConnectivityStatus.limited,
    2 => NetworkConnectivityStatus.captivePortal,
    _ when deviceState == 100 || managerState >= 50 =>
      NetworkConnectivityStatus.local,
    _ => NetworkConnectivityStatus.disconnected,
  };
}

@visibleForTesting
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
        savedConnectionPath: saved.objectPath,
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
      accessPointPath: '/',
      savedConnectionPath: saved.objectPath,
      connected: false,
      available: false,
    );
  }

  final networks = visible.values.toList(growable: false)
    ..sort((left, right) {
      final connected = _trueFirst(left.connected, right.connected);
      if (connected != 0) {
        return connected;
      }
      final saved = _trueFirst(left.saved, right.saved);
      if (saved != 0) {
        return saved;
      }
      final available = _trueFirst(left.available, right.available);
      if (available != 0) {
        return available;
      }
      final strength = right.strength.compareTo(left.strength);
      if (strength != 0) {
        return strength;
      }
      return left.ssid.toLowerCase().compareTo(right.ssid.toLowerCase());
    });
  return List<WifiNetwork>.unmodifiable(networks.take(maximum));
}

@visibleForTesting
DBusDict buildWifiConnectionSettings(WifiNetwork network, {String? password}) {
  final value = password ?? '';
  final sections = <String, Map<String, DBusValue>>{
    'connection': <String, DBusValue>{
      'id': DBusString(network.ssid),
      'type': const DBusString('802-11-wireless'),
      'autoconnect': const DBusBoolean(true),
    },
    '802-11-wireless': <String, DBusValue>{
      'ssid': DBusArray.byte(network.ssidBytes),
      'mode': const DBusString('infrastructure'),
    },
    'ipv4': <String, DBusValue>{'method': const DBusString('auto')},
    'ipv6': <String, DBusValue>{'method': const DBusString('auto')},
  };

  switch (network.security) {
    case WifiSecurity.open:
      break;
    case WifiSecurity.owe:
      sections['802-11-wireless-security'] = <String, DBusValue>{
        'key-mgmt': const DBusString('owe'),
      };
    case WifiSecurity.wpaPersonal:
      _validatePsk(value);
      sections['802-11-wireless-security'] = <String, DBusValue>{
        'key-mgmt': const DBusString('wpa-psk'),
        'psk': DBusString(value),
      };
    case WifiSecurity.wpa3Personal:
      _validatePsk(value);
      sections['802-11-wireless-security'] = <String, DBusValue>{
        'key-mgmt': const DBusString('sae'),
        'psk': DBusString(value),
      };
    case WifiSecurity.wep:
      if (value.length < 5 || value.length > 64) {
        throw ArgumentError.value(
          value.length,
          'password',
          'WEP keys must contain between 5 and 64 characters',
        );
      }
      sections['802-11-wireless-security'] = <String, DBusValue>{
        'key-mgmt': const DBusString('none'),
        'wep-key0': DBusString(value),
        'wep-tx-keyidx': const DBusUint32(0),
      };
    case WifiSecurity.enterprise:
    case WifiSecurity.unknown:
      throw StateError('This Wi-Fi security type needs a saved system profile');
  }

  return DBusDict(
    DBusSignature('s'),
    DBusSignature('a{sv}'),
    <DBusValue, DBusValue>{
      for (final section in sections.entries)
        DBusString(section.key): DBusDict.stringVariant(section.value),
    },
  );
}

void _validatePsk(String value) {
  final hex = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
  if (!hex && (value.length < 8 || value.length > 63)) {
    throw ArgumentError.value(
      value.length,
      'password',
      'Wi-Fi passwords must contain 8–63 characters',
    );
  }
}

WifiSecurity _savedSecurity(Map<String, Map<String, DBusValue>> settings) {
  final security = settings['802-11-wireless-security'];
  final keyManagement = _string(security, 'key-mgmt');
  return switch (keyManagement) {
    '' => WifiSecurity.open,
    'none' => WifiSecurity.wep,
    'wpa-psk' => WifiSecurity.wpaPersonal,
    'sae' => WifiSecurity.wpa3Personal,
    'owe' => WifiSecurity.owe,
    'wpa-eap' || 'ieee8021x' => WifiSecurity.enterprise,
    _ => WifiSecurity.unknown,
  };
}

Map<String, Map<String, DBusValue>> _settingsMap(DBusValue value) {
  final result = <String, Map<String, DBusValue>>{};
  for (final entry in value.asDict().entries) {
    result[entry.key.asString()] = entry.value.asStringVariantDict();
  }
  return result;
}

bool _boolean(Map<String, DBusValue>? values, String key) {
  final value = values?[key];
  return value is DBusBoolean && value.value;
}

int _byte(Map<String, DBusValue>? values, String key) {
  final value = values?[key];
  return value is DBusByte ? value.value : 0;
}

int _uint32(Map<String, DBusValue>? values, String key) {
  final value = values?[key];
  return value is DBusUint32 ? value.value : 0;
}

int _int64(
  Map<String, DBusValue>? values,
  String key, {
  required int fallback,
}) {
  final value = values?[key];
  return value is DBusInt64 ? value.value : fallback;
}

String _string(
  Map<String, DBusValue>? values,
  String key, {
  String fallback = '',
}) {
  final value = values?[key];
  return value is DBusString && value.value.trim().isNotEmpty
      ? value.value.trim()
      : fallback;
}

List<int> _bytes(Map<String, DBusValue>? values, String key) {
  final value = values?[key];
  return value is DBusArray && value.signature == DBusSignature('ay')
      ? value.asByteArray().toList(growable: false)
      : const <int>[];
}

String? _objectPath(Map<String, DBusValue>? values, String key) {
  final value = values?[key];
  if (value is! DBusObjectPath || value.value == '/') {
    return null;
  }
  return value.value;
}

List<String> _objectPaths(Map<String, DBusValue>? values, String key) {
  final value = values?[key];
  return value is DBusArray && value.signature == DBusSignature('ao')
      ? value
            .asObjectPathArray()
            .take(NetworkManagerService._maxAccessPoints)
            .map((path) => path.value)
            .toList(growable: false)
      : const <String>[];
}

NetworkPermission _permission(String? value) => switch (value) {
  'yes' => NetworkPermission.allowed,
  'auth' => NetworkPermission.authenticationRequired,
  'no' => NetworkPermission.denied,
  _ => NetworkPermission.unknown,
};

NetworkPermission _strongestPermission(
  NetworkPermission left,
  NetworkPermission right,
) {
  const priority = <NetworkPermission, int>{
    NetworkPermission.allowed: 3,
    NetworkPermission.authenticationRequired: 2,
    NetworkPermission.unknown: 1,
    NetworkPermission.denied: 0,
  };
  return priority[left]! >= priority[right]! ? left : right;
}

int _trueFirst(bool left, bool right) {
  if (left == right) {
    return 0;
  }
  return left ? -1 : 1;
}

class _WifiDeviceSnapshot {
  const _WifiDeviceSnapshot({
    required this.path,
    required this.state,
    required this.activeConnectionPath,
    required this.activeAccessPointPath,
    required this.accessPoints,
    required this.lastScan,
  });

  final String path;
  final int state;
  final String? activeConnectionPath;
  final String? activeAccessPointPath;
  final List<String> accessPoints;
  final int lastScan;
}

class _NetworkPermissions {
  const _NetworkPermissions({
    this.radio = NetworkPermission.unknown,
    this.control = NetworkPermission.unknown,
    this.modify = NetworkPermission.unknown,
  });

  final NetworkPermission radio;
  final NetworkPermission control;
  final NetworkPermission modify;
}
