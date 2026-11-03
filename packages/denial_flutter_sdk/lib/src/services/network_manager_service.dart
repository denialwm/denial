import 'dart:async';
import 'dart:convert';

import 'package:dbus/dbus.dart';
import 'package:meta/meta.dart';

import 'network_backend.dart';

export 'network_backend.dart';

class NetworkManagerService implements NetworkBackend {
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
  static const String _propertiesInterface = 'org.freedesktop.DBus.Properties';

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
  final StreamController<NetworkSnapshot> _snapshots =
      StreamController<NetworkSnapshot>.broadcast(sync: true);

  StreamSubscription<DBusSignal>? _signalSubscription;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerSubscription;
  Timer? _refreshTimer;
  bool _started = false;
  bool _disposed = false;
  Completer<void>? _refreshCompletion;
  bool _refreshAgain = false;
  NetworkSnapshot _current = NetworkSnapshot.unavailable();

  // The NetworkManager objects behind [_current]. NetworkManager reports
  // every signal-strength and bitrate change of every visible access point;
  // patching those values here keeps them from costing a full D-Bus re-read.
  _NetworkObjects? _objects;

  // GetPermissions makes NetworkManager run one polkit check per action, so
  // the answer is kept until NetworkManager announces CheckPermissions.
  _NetworkPermissions? _permissions;
  int _permissionEpoch = 0;

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  @override
  NetworkSnapshot get currentSnapshot => _current;

  @override
  Future<void> start() {
    if (_disposed) return Future<void>.value();
    if (_started) return _refreshCompletion?.future ?? Future<void>.value();
    _started = true;
    _signalSubscription = DBusSignalStream(
      _client,
      sender: _serviceName,
      pathNamespace: DBusObjectPath(_rootPath),
    ).listen(_handleSignal, onError: (_) => _scheduleRefresh());
    _ownerSubscription = _client.nameOwnerChanged
        .where((event) => event.name == _serviceName)
        .listen((event) {
          _objects = null;
          _forgetPermissions();
          if (event.newOwner == null) {
            _refreshTimer?.cancel();
            _emit(NetworkSnapshot.unavailable());
          } else {
            _scheduleRefresh(immediate: true);
          }
        });
    return refresh();
  }

  @override
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _refreshAgain = true;
    if (_refreshCompletion case final completion?) return completion.future;
    final completion = _refreshCompletion = Completer<void>();
    unawaited(_refreshSnapshots(completion));
    return completion.future;
  }

  Future<void> _refreshSnapshots(Completer<void> completion) async {
    try {
      while (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        _refreshTimer?.cancel();
        _refreshTimer = null;
        try {
          final snapshot = await _readSnapshot();
          _emit(snapshot);
        } on Object {
          _emit(NetworkSnapshot.unavailable());
        }
      }
      completion.complete();
    } on Object catch (error, stackTrace) {
      completion.completeError(error, stackTrace);
    } finally {
      _refreshCompletion = null;
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
      network.networkPath.isEmpty ? '/' : network.networkPath,
    );
    final saved = network.savedNetworkPath;
    if (saved != null) {
      await _root
          .callMethod(_managerInterface, 'ActivateConnection', <DBusValue>[
            DBusObjectPath(saved),
            device,
            accessPoint,
          ], replySignature: DBusSignature('o'))
          .timeout(_methodTimeout);
      return;
    }

    final settings = buildWifiConnectionSettings(network, password: password);
    await _root
        .callMethod(_managerInterface, 'AddAndActivateConnection2', <DBusValue>[
          settings,
          device,
          accessPoint,
          DBusDict.stringVariant(const <String, DBusValue>{}),
        ], replySignature: DBusSignature('ooa{sv}'))
        .timeout(_methodTimeout);
  }

  @override
  Future<void> disconnect() async {
    final activeConnection = _current.activeNetworkPath;
    if (activeConnection == null || activeConnection == '/') {
      return;
    }
    await _root
        .callMethod(_managerInterface, 'DeactivateConnection', <DBusValue>[
          DBusObjectPath(activeConnection),
        ], replySignature: DBusSignature(''))
        .timeout(_methodTimeout);
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    final path = network.savedNetworkPath;
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

  Future<NetworkSnapshot> _readSnapshot() async {
    // Property signals that arrive during the read are not patched into
    // objects the read may already have passed; they request another read.
    _objects = null;
    if (!await _client.nameHasOwner(_serviceName).timeout(_readTimeout) ||
        _disposed) {
      return NetworkSnapshot.unavailable();
    }

    // These independent reads share one round trip window. Device/AP reads
    // remain bounded by the existing per-batch limit below.
    final (manager, permissions, deviceReply) = await (
      _root.getAllProperties(_managerInterface).timeout(_readTimeout),
      _currentPermissions(),
      _root
          .callMethod(
            _managerInterface,
            'GetDevices',
            const <DBusValue>[],
            replySignature: DBusSignature('ao'),
          )
          .timeout(_readTimeout),
    ).wait;
    if (_disposed) return NetworkSnapshot.unavailable();
    final devicePaths = deviceReply.returnValues.first
        .asObjectPathArray()
        .take(_maxDevices)
        .toList(growable: false);
    final devices = (await _mapInBatches(devicePaths, _readBatchSize, (
      path,
    ) async {
      final device = await _tryGetAll(path.value, _deviceInterface);
      if (_uint32(device, 'DeviceType') != 2) {
        return null;
      }
      final wireless = await _tryGetAll(path.value, _wirelessInterface);
      return _WifiDeviceObjects(path.value, {...device}, {...wireless});
    })).whereType<_WifiDeviceObjects>().toList(growable: false);
    if (_disposed) return NetworkSnapshot.unavailable();

    final accessPointPaths = _accessPointOwners(_sortedWifiDevices(devices))
        .keys;
    final accessPoints = Map.fromEntries(
      await _mapInBatches(
        accessPointPaths,
        _readBatchSize,
        (path) async =>
            MapEntry(path, {...await _tryGetAll(path, _accessPointInterface)}),
      ),
    );
    if (_disposed) return NetworkSnapshot.unavailable();
    final savedConnections = devices.isEmpty
        ? const <SavedWifiConnectionInfo>[]
        : await _readSavedConnections();
    if (_disposed) return NetworkSnapshot.unavailable();
    final objects = _objects = _NetworkObjects(
      manager: {...manager},
      permissions: permissions,
      devices: devices,
      accessPoints: accessPoints,
      savedConnections: savedConnections,
    );
    return _composeSnapshot(objects);
  }

  void _handleSignal(DBusSignal signal) {
    if (_disposed) {
      return;
    }
    if (signal.interface == _propertiesInterface &&
        signal.name == 'PropertiesChanged') {
      switch (_patchProperties(signal)) {
        case _PropertyPatch.irrelevant:
          return;
        case _PropertyPatch.applied:
          _emit(_composeSnapshot(_objects!));
          return;
        case _PropertyPatch.needsRead:
          break;
      }
    } else if (signal.interface == _managerInterface &&
        signal.name == 'CheckPermissions') {
      _forgetPermissions();
    }
    _scheduleRefresh();
  }

  /// Applies a PropertiesChanged signal to [_objects] when it only changes
  /// values the snapshot is composed from. Object lists name objects that
  /// were never read, so a change to one of them needs a full read.
  _PropertyPatch _patchProperties(DBusSignal signal) {
    if (signal.values.length != 3) {
      return _PropertyPatch.needsRead;
    }
    final [interface, changed, invalidated] = signal.values;
    if (interface is! DBusString ||
        changed is! DBusDict ||
        invalidated is! DBusArray) {
      return _PropertyPatch.needsRead;
    }
    final path = signal.path.value;
    final objects = _objects;
    final Map<String, DBusValue>? target;
    var references = const <String>{};
    switch (interface.value) {
      case _managerInterface when path == _rootPath:
        target = objects?.manager;
        references = const {'Devices', 'AllDevices'};
      case _deviceInterface:
        target = objects?.device(path)?.device;
        references = const {'DeviceType'};
      case _wirelessInterface:
        target = objects?.device(path)?.wireless;
        references = const {'AccessPoints', 'ActiveAccessPoint'};
      case _accessPointInterface:
        target = objects?.accessPoints[path];
      default:
        // Active connections, IP configurations, statistics and connection
        // flags are not part of the snapshot.
        return _PropertyPatch.irrelevant;
    }
    if (objects == null) {
      return _PropertyPatch.needsRead;
    }
    // Other devices and access points beyond the read limit are not shown;
    // a new one is announced through a reference list first.
    if (target == null) {
      return _PropertyPatch.irrelevant;
    }
    final values = changed.asStringVariantDict();
    if (invalidated.children.isNotEmpty ||
        values.keys.any(references.contains)) {
      return _PropertyPatch.needsRead;
    }
    target.addAll(values);
    return _PropertyPatch.applied;
  }

  static NetworkSnapshot _composeSnapshot(_NetworkObjects objects) {
    final rootProperties = objects.manager;
    final permissions = objects.permissions;
    final wirelessEnabled = _boolean(rootProperties, 'WirelessEnabled');
    final hardwareEnabled = _boolean(rootProperties, 'WirelessHardwareEnabled');
    final wifiDevices = _sortedWifiDevices(objects.devices);
    if (wifiDevices.isEmpty) {
      return NetworkSnapshot(
        serviceAvailable: true,
        wifiDeviceAvailable: false,
        wirelessHardwareEnabled: hardwareEnabled,
        wirelessEnabled: wirelessEnabled,
        status: NetworkConnectivityStatus.unavailable,
        networks: const <WifiNetwork>[],
        activeNetworkPath: null,
        devicePath: null,
        lastScan: -1,
        radioPermission: permissions.radio,
        controlPermission: permissions.control,
        modifyPermission: permissions.modify,
      );
    }

    final primaryDevice = wifiDevices.first;
    final candidates = <WifiNetwork>[];
    for (final MapEntry(key: path, value: device) in _accessPointOwners(
      wifiDevices,
    ).entries) {
      final properties = objects.accessPoints[path];
      final ssidBytes = _bytes(properties, 'Ssid');
      if (ssidBytes.isEmpty || ssidBytes.length > 32) {
        continue;
      }
      final security = classifyWifiSecurity(
        flags: _uint32(properties, 'Flags'),
        wpaFlags: _uint32(properties, 'WpaFlags'),
        rsnFlags: _uint32(properties, 'RsnFlags'),
      );
      candidates.add(
        WifiNetwork(
          ssid: utf8.decode(ssidBytes, allowMalformed: true),
          ssidBytes: ssidBytes,
          security: security,
          strength: _byte(properties, 'Strength'),
          frequency: _uint32(properties, 'Frequency'),
          devicePath: device.path,
          networkPath: path,
          savedNetworkPath: null,
          connected:
              device.state == 100 && device.activeAccessPointPath == path,
          available: true,
        ),
      );
    }

    final networks = normalizeWifiNetworks(
      candidates,
      objects.savedConnections,
      defaultDevicePath: primaryDevice.path,
    );
    final activeConnection = wifiDevices
        .map((device) => device.activeNetworkPath)
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

    return NetworkSnapshot(
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
      activeNetworkPath: activeConnection,
      devicePath: primaryDevice.path,
      lastScan: lastScan,
      radioPermission: permissions.radio,
      controlPermission: permissions.control,
      modifyPermission: permissions.modify,
    );
  }

  /// Wi-Fi devices with an active connection first.
  static List<_WifiDeviceSnapshot> _sortedWifiDevices(
    Iterable<_WifiDeviceObjects> devices,
  ) {
    return devices.map((device) => device.snapshot).toList()
      ..sort((left, right) {
        final leftActive = left.activeNetworkPath != null ? 1 : 0;
        final rightActive = right.activeNetworkPath != null ? 1 : 0;
        return rightActive.compareTo(leftActive);
      });
  }

  /// The shown access points, each with the first device that sees it.
  static Map<String, _WifiDeviceSnapshot> _accessPointOwners(
    List<_WifiDeviceSnapshot> devices,
  ) {
    final owners = <String, _WifiDeviceSnapshot>{};
    for (final device in devices) {
      for (final path in device.accessPoints) {
        if (owners.length == _maxAccessPoints) {
          break;
        }
        owners.putIfAbsent(path, () => device);
      }
    }
    return owners;
  }

  Future<_NetworkPermissions> _currentPermissions() async {
    if (_permissions case final permissions?) {
      return permissions;
    }
    final epoch = _permissionEpoch;
    final permissions = await _readPermissions();
    // A CheckPermissions signal during the read leaves this answer stale;
    // the read it requested asks again.
    if (permissions != null && epoch == _permissionEpoch) {
      _permissions = permissions;
    }
    return permissions ?? const _NetworkPermissions();
  }

  void _forgetPermissions() {
    _permissions = null;
    _permissionEpoch++;
  }

  Future<_NetworkPermissions?> _readPermissions() async {
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
      return null;
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
    if (_disposed) return const {};
    try {
      return await _object(path)
          .getAllProperties(interface)
          .timeout(_readTimeout);
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

  void _emit(NetworkSnapshot snapshot) {
    if (_disposed || snapshot == _current) {
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
    _refreshAgain = false;
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
  if (deviceState != 100) {
    return NetworkConnectivityStatus.disconnected;
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

class _WifiDeviceSnapshot {
  const _WifiDeviceSnapshot({
    required this.path,
    required this.state,
    required this.activeNetworkPath,
    required this.activeAccessPointPath,
    required this.accessPoints,
    required this.lastScan,
  });

  final String path;
  final int state;
  final String? activeNetworkPath;
  final String? activeAccessPointPath;
  final List<String> accessPoints;
  final int lastScan;
}

class _WifiDeviceObjects {
  _WifiDeviceObjects(this.path, this.device, this.wireless);

  final String path;
  final Map<String, DBusValue> device;
  final Map<String, DBusValue> wireless;

  _WifiDeviceSnapshot get snapshot => _WifiDeviceSnapshot(
    path: path,
    state: _uint32(device, 'State'),
    activeNetworkPath: _objectPath(device, 'ActiveConnection'),
    activeAccessPointPath: _objectPath(wireless, 'ActiveAccessPoint'),
    accessPoints: _objectPaths(wireless, 'AccessPoints'),
    lastScan: _int64(wireless, 'LastScan', fallback: -1),
  );
}

class _NetworkObjects {
  _NetworkObjects({
    required this.manager,
    required this.permissions,
    required this.devices,
    required this.accessPoints,
    required this.savedConnections,
  });

  final Map<String, DBusValue> manager;
  final _NetworkPermissions permissions;
  final List<_WifiDeviceObjects> devices;
  final Map<String, Map<String, DBusValue>> accessPoints;
  final List<SavedWifiConnectionInfo> savedConnections;

  _WifiDeviceObjects? device(String path) =>
      devices.where((device) => device.path == path).firstOrNull;
}

enum _PropertyPatch { irrelevant, applied, needsRead }

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
