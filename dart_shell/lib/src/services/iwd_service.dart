import 'dart:async';
import 'dart:convert';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'network_backend.dart';

/// Direct iwd integration for systems that leave IP configuration to
/// systemd-networkd. iwd owns association and saved Wi-Fi credentials;
/// networkd is consulted only for the selected link's configured state.
class IwdService implements NetworkBackend {
  factory IwdService({DBusClient? client}) {
    return IwdService._(client ?? DBusClient.system());
  }

  IwdService._(this._client)
    : _manager = DBusRemoteObjectManager(
        _client,
        name: serviceName,
        path: DBusObjectPath.root,
      ),
      _agentManager = DBusRemoteObject(
        _client,
        name: serviceName,
        path: DBusObjectPath(_iwdPath),
      ),
      _networkdManager = DBusRemoteObject(
        _client,
        name: _networkdService,
        path: DBusObjectPath(_networkdPath),
      ),
      _agent = IwdAgentEndpoint();

  static const String serviceName = 'net.connman.iwd';
  static const String _iwdPath = '/net/connman/iwd';
  static const String _adapterInterface = 'net.connman.iwd.Adapter';
  static const String _deviceInterface = 'net.connman.iwd.Device';
  static const String _stationInterface = 'net.connman.iwd.Station';
  static const String _networkInterface = 'net.connman.iwd.Network';
  static const String _knownNetworkInterface = 'net.connman.iwd.KnownNetwork';
  static const String _agentManagerInterface = 'net.connman.iwd.AgentManager';
  static const String _agentPath = '/org/denial/IwdAgent';

  static const String _networkdService = 'org.freedesktop.network1';
  static const String _networkdPath = '/org/freedesktop/network1';
  static const String _networkdManagerInterface =
      'org.freedesktop.network1.Manager';
  static const String _networkdLinkInterface = 'org.freedesktop.network1.Link';

  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _methodTimeout = Duration(seconds: 45);
  static const Duration _signalCoalesce = Duration(milliseconds: 55);
  static const int _maxAdapters = 8;
  static const int _maxDevices = 16;
  static const int _maxNetworks = 128;

  final DBusClient _client;
  final DBusRemoteObjectManager _manager;
  final DBusRemoteObject _agentManager;
  final DBusRemoteObject _networkdManager;
  final IwdAgentEndpoint _agent;
  final StreamController<NetworkSnapshot> _snapshots =
      StreamController<NetworkSnapshot>.broadcast(sync: true);
  final Map<String, String> _pendingPassphrases = <String, String>{};

  StreamSubscription<DBusSignal>? _iwdSignals;
  StreamSubscription<DBusSignal>? _networkdSignals;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerChanges;
  Timer? _refreshTimer;
  String? _iwdOwner;
  String? _scanningStationPath;
  List<String> _adapterPaths = const <String>[];
  List<String> _radioPaths = const <String>[];
  String _radioInterface = _adapterInterface;
  NetworkSnapshot _current = const NetworkSnapshot.unavailable();
  int _lastScan = -1;
  bool _started = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _agentRegistered = false;

  @override
  Stream<NetworkSnapshot> get snapshots => _snapshots.stream;

  @override
  NetworkSnapshot get currentSnapshot => _current;

  @override
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _agent.owner = () => _iwdOwner;
    _agent.passphraseFor = (path) => _pendingPassphrases[path];
    _agent.onReleased = () {
      _agentRegistered = false;
      _pendingPassphrases.clear();
    };
    await _client.registerObject(_agent);
    _iwdSignals = _manager.signals.listen(
      _handleIwdSignal,
      onError: (_) => _scheduleRefresh(),
    );
    _networkdSignals = DBusSignalStream(
      _client,
      sender: _networkdService,
      pathNamespace: DBusObjectPath(_networkdPath),
    ).listen((_) => _scheduleRefresh(), onError: (_) => _scheduleRefresh());
    _ownerChanges = _client.nameOwnerChanged
        .where(
          (event) =>
              event.name == serviceName || event.name == _networkdService,
        )
        .listen(_handleOwnerChanged);
    _iwdOwner = await _client.getNameOwner(serviceName).timeout(_readTimeout);
    if (_iwdOwner != null) {
      await _tryRegisterAgent();
    }
    await refresh();
  }

  void _handleIwdSignal(DBusSignal signal) {
    if (signal is DBusPropertiesChangedSignal &&
        signal.propertiesInterface == _stationInterface &&
        signal.path.value == _scanningStationPath) {
      final scanning = signal.changedProperties['Scanning'];
      if (scanning is DBusBoolean && !scanning.value) {
        _lastScan = _lastScan < 0 ? 0 : _lastScan + 1;
        _scanningStationPath = null;
      }
    }
    _scheduleRefresh();
  }

  void _handleOwnerChanged(DBusNameOwnerChangedEvent event) {
    if (event.name == _networkdService) {
      _scheduleRefresh(immediate: true);
      return;
    }
    _iwdOwner = event.newOwner;
    _agentRegistered = false;
    _pendingPassphrases.clear();
    if (event.newOwner == null) {
      _refreshTimer?.cancel();
      _emit(const NetworkSnapshot.unavailable());
      return;
    }
    unawaited(_recoverIwd());
  }

  Future<void> _recoverIwd() async {
    await _tryRegisterAgent();
    _scheduleRefresh(immediate: true);
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
        _emit(const NetworkSnapshot.unavailable());
      }
    } finally {
      _refreshing = false;
      if (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        _scheduleRefresh(immediate: true);
      }
    }
  }

  Future<NetworkSnapshot> _readSnapshot() async {
    final owner =
        _iwdOwner ??
        await _client.getNameOwner(serviceName).timeout(_readTimeout);
    if (owner == null) {
      return const NetworkSnapshot.unavailable();
    }
    _iwdOwner = owner;

    final managed = await _manager.getManagedObjects().timeout(_readTimeout);
    final adapters = <_IwdAdapter>[];
    final devices = <_IwdDevice>[];
    for (final entry in managed.entries) {
      final adapter = entry.value[_adapterInterface];
      if (adapter != null && adapters.length < _maxAdapters) {
        adapters.add(
          _IwdAdapter(
            path: entry.key.value,
            powered: _boolean(adapter, 'Powered'),
            supportsStation: _strings(
              adapter,
              'SupportedModes',
            ).contains('station'),
          ),
        );
      }

      final device = entry.value[_deviceInterface];
      if (device != null && devices.length < _maxDevices) {
        final station = entry.value[_stationInterface];
        devices.add(
          _IwdDevice(
            path: entry.key.value,
            name: _string(device, 'Name'),
            mode: _string(device, 'Mode'),
            powered: _boolean(device, 'Powered'),
            station: station != null,
            state: _string(station, 'State', fallback: 'disconnected'),
            connectedNetworkPath: _objectPath(station, 'ConnectedNetwork'),
          ),
        );
      }
    }

    final stationAdapters = adapters
        .where((adapter) => adapter.supportsStation)
        .toList(growable: false);
    final stationDevices =
        devices.where((device) => device.station).toList(growable: false)
          ..sort(_compareDevices);
    final wifiDevices = devices
        .where((device) => device.station || device.mode == 'station')
        .toList(growable: false);
    final wifiDeviceAvailable =
        stationAdapters.isNotEmpty || wifiDevices.isNotEmpty;
    final wirelessEnabled = wifiDevices.isNotEmpty
        ? wifiDevices.any((device) => device.powered)
        : stationAdapters.any((adapter) => adapter.powered);
    _adapterPaths = stationAdapters
        .map((adapter) => adapter.path)
        .toList(growable: false);
    _radioPaths = wifiDevices.isNotEmpty
        ? wifiDevices.map((device) => device.path).toList(growable: false)
        : stationAdapters
              .map((adapter) => adapter.path)
              .toList(growable: false);
    _radioInterface = wifiDevices.isNotEmpty
        ? _deviceInterface
        : _adapterInterface;

    final primary = stationDevices.isNotEmpty ? stationDevices.first : null;
    final fallbackDevicePath =
        primary?.path ?? (devices.isEmpty ? '' : devices.first.path);
    final candidates = await _readVisibleNetworks(managed, stationDevices);
    final saved = _readKnownNetworks(managed);
    final networks = normalizeWifiNetworks(
      candidates,
      saved,
      defaultDevicePath: fallbackDevicePath,
    );
    final state = primary?.state ?? 'disconnected';
    final networkdState = state == 'connected' && primary != null
        ? await _readNetworkdState(primary.name)
        : null;

    return NetworkSnapshot(
      serviceAvailable: true,
      wifiDeviceAvailable: wifiDeviceAvailable,
      wirelessHardwareEnabled: wifiDeviceAvailable,
      wirelessEnabled: wirelessEnabled,
      status: _connectivityStatus(
        wirelessEnabled: wirelessEnabled,
        stationState: state,
        networkd: networkdState,
      ),
      networks: networks,
      activeNetworkPath: primary?.connectedNetworkPath,
      devicePath: fallbackDevicePath.isEmpty ? null : fallbackDevicePath,
      lastScan: _lastScan,
      radioPermission: NetworkPermission.unknown,
      controlPermission: NetworkPermission.unknown,
      modifyPermission: NetworkPermission.unknown,
    );
  }

  Future<List<WifiNetwork>> _readVisibleNetworks(
    Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> managed,
    List<_IwdDevice> stations,
  ) async {
    final networks = <WifiNetwork>[];
    for (final station in stations) {
      if (!station.powered) {
        continue;
      }
      late final DBusMethodSuccessResponse reply;
      try {
        reply = await _object(station.path)
            .callMethod(
              _stationInterface,
              'GetOrderedNetworks',
              const <DBusValue>[],
              replySignature: DBusSignature('a(on)'),
            )
            .timeout(_readTimeout);
      } on Object {
        continue;
      }
      final ordered = reply.returnValues.first;
      if (ordered is! DBusArray) {
        continue;
      }
      for (final value in ordered.children.take(_maxNetworks)) {
        if (value is! DBusStruct || value.children.length != 2) {
          continue;
        }
        final pathValue = value.children[0];
        final signalValue = value.children[1];
        if (pathValue is! DBusObjectPath || signalValue is! DBusInt16) {
          continue;
        }
        final properties = managed[pathValue]?[_networkInterface];
        if (properties == null) {
          continue;
        }
        final name = _string(properties, 'Name');
        final ssidBytes = utf8.encode(name);
        if (ssidBytes.isEmpty || ssidBytes.length > 32) {
          continue;
        }
        final security = _iwdSecurity(_string(properties, 'Type'));
        networks.add(
          WifiNetwork(
            ssid: name,
            ssidBytes: ssidBytes,
            security: security,
            strength: _signalPercent(signalValue.value),
            frequency: 0,
            devicePath: _objectPath(properties, 'Device') ?? station.path,
            networkPath: pathValue.value,
            savedNetworkPath: _objectPath(properties, 'KnownNetwork'),
            connected: _boolean(properties, 'Connected'),
            available: true,
            supported:
                security != WifiSecurity.wep &&
                security != WifiSecurity.unknown,
          ),
        );
      }
    }
    return networks;
  }

  List<SavedWifiConnectionInfo> _readKnownNetworks(
    Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> managed,
  ) {
    final saved = <SavedWifiConnectionInfo>[];
    for (final entry in managed.entries) {
      final properties = entry.value[_knownNetworkInterface];
      if (properties == null || saved.length == _maxNetworks) {
        continue;
      }
      final name = _string(properties, 'Name');
      final ssidBytes = utf8.encode(name);
      final security = _iwdSecurity(_string(properties, 'Type'));
      if (ssidBytes.isEmpty ||
          ssidBytes.length > 32 ||
          security == WifiSecurity.unknown ||
          security == WifiSecurity.wep) {
        continue;
      }
      saved.add(
        SavedWifiConnectionInfo(
          objectPath: entry.key.value,
          name: name,
          ssidBytes: ssidBytes,
          security: security,
        ),
      );
    }
    return saved;
  }

  Future<_NetworkdLinkState?> _readNetworkdState(String interfaceName) async {
    if (interfaceName.isEmpty) {
      return null;
    }
    try {
      if (!await _client.nameHasOwner(_networkdService).timeout(_readTimeout)) {
        return null;
      }
      final reply = await _networkdManager
          .callMethod(
            _networkdManagerInterface,
            'GetLinkByName',
            <DBusValue>[DBusString(interfaceName)],
            replySignature: DBusSignature('io'),
          )
          .timeout(_readTimeout);
      final link = DBusRemoteObject(
        _client,
        name: _networkdService,
        path: reply.returnValues[1].asObjectPath(),
      );
      final properties = await link
          .getAllProperties(_networkdLinkInterface)
          .timeout(_readTimeout);
      return _NetworkdLinkState(
        operational: _string(properties, 'OperationalState'),
        address: _string(properties, 'AddressState'),
        online: _string(properties, 'OnlineState'),
        administrative: _string(properties, 'AdministrativeState'),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    if (_radioPaths.isEmpty) {
      await refresh();
    }
    if (_radioPaths.isEmpty) {
      throw StateError('No Wi-Fi adapter is available');
    }
    if (enabled && _radioInterface == _deviceInterface) {
      for (final path in _adapterPaths) {
        await _object(path)
            .setProperty(_adapterInterface, 'Powered', const DBusBoolean(true))
            .timeout(_methodTimeout);
      }
    }
    for (final path in _radioPaths) {
      await _object(path)
          .setProperty(_radioInterface, 'Powered', DBusBoolean(enabled))
          .timeout(_methodTimeout);
    }
    await refresh();
  }

  @override
  Future<void> requestScan() async {
    final stationPath = _current.devicePath;
    if (stationPath == null || !_current.wirelessEnabled) {
      throw StateError('No powered Wi-Fi adapter is available');
    }
    _scanningStationPath = stationPath;
    try {
      await _object(stationPath)
          .callMethod(
            _stationInterface,
            'Scan',
            const <DBusValue>[],
            replySignature: DBusSignature(''),
          )
          .timeout(_methodTimeout);
    } on Object {
      _scanningStationPath = null;
      rethrow;
    }
  }

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    if (!network.connectable || network.networkPath.isEmpty) {
      throw StateError('This Wi-Fi network cannot be connected');
    }
    if (!network.saved && network.security.requiresPassword) {
      final passphrase = password ?? '';
      _validatePassphrase(passphrase);
      await _ensureAgent();
      _pendingPassphrases[network.networkPath] = passphrase;
    }
    try {
      await _object(network.networkPath)
          .callMethod(
            _networkInterface,
            'Connect',
            const <DBusValue>[],
            replySignature: DBusSignature(''),
          )
          .timeout(_methodTimeout);
    } finally {
      _pendingPassphrases.remove(network.networkPath);
    }
  }

  @override
  Future<void> disconnect() async {
    final stationPath = _current.devicePath;
    if (stationPath == null || _current.activeNetworkPath == null) {
      return;
    }
    await _object(stationPath)
        .callMethod(
          _stationInterface,
          'Disconnect',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    final path = network.savedNetworkPath;
    if (path == null) {
      return;
    }
    await _object(path)
        .callMethod(
          _knownNetworkInterface,
          'Forget',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
  }

  Future<void> _ensureAgent() async {
    if (!_agentRegistered) {
      await _tryRegisterAgent();
    }
    if (!_agentRegistered) {
      throw StateError('The iwd credential agent is unavailable');
    }
  }

  Future<void> _tryRegisterAgent() async {
    if (_disposed || _iwdOwner == null || _agentRegistered) {
      return;
    }
    try {
      await _agentManager
          .callMethod(
            _agentManagerInterface,
            'RegisterAgent',
            <DBusValue>[DBusObjectPath(_agentPath)],
            replySignature: DBusSignature(''),
          )
          .timeout(_readTimeout);
      _agentRegistered = true;
    } on DBusMethodResponseException catch (error) {
      if (error.errorName != 'net.connman.iwd.AlreadyExists') {
        return;
      }
    } on Object {
      return;
    }
  }

  DBusRemoteObject _object(String path) =>
      DBusRemoteObject(_client, name: serviceName, path: DBusObjectPath(path));

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
    _pendingPassphrases.clear();
    await _iwdSignals?.cancel();
    await _networkdSignals?.cancel();
    await _ownerChanges?.cancel();
    if (_agentRegistered && _iwdOwner != null) {
      try {
        await _agentManager
            .callMethod(
              _agentManagerInterface,
              'UnregisterAgent',
              <DBusValue>[DBusObjectPath(_agentPath)],
              replySignature: DBusSignature(''),
            )
            .timeout(_readTimeout);
      } on Object {
        // Closing the private connection also releases the iwd agent.
      }
    }
    try {
      await _client.unregisterObject(_agent);
    } on Object {
      // Closing the private connection also unregisters the local object.
    }
    await _snapshots.close();
    await _client.close();
  }
}

@visibleForTesting
NetworkConnectivityStatus classifyIwdConnectivity({
  required bool wirelessEnabled,
  required String stationState,
  String operationalState = '',
  String addressState = '',
  String onlineState = '',
  String administrativeState = '',
}) {
  return _connectivityStatus(
    wirelessEnabled: wirelessEnabled,
    stationState: stationState,
    networkd: _NetworkdLinkState(
      operational: operationalState,
      address: addressState,
      online: onlineState,
      administrative: administrativeState,
    ),
  );
}

NetworkConnectivityStatus _connectivityStatus({
  required bool wirelessEnabled,
  required String stationState,
  required _NetworkdLinkState? networkd,
}) {
  if (!wirelessEnabled) {
    return NetworkConnectivityStatus.disabled;
  }
  if (stationState == 'connecting' ||
      stationState == 'disconnecting' ||
      stationState == 'roaming') {
    return NetworkConnectivityStatus.connecting;
  }
  if (stationState != 'connected') {
    return NetworkConnectivityStatus.disconnected;
  }
  if (networkd == null) {
    return NetworkConnectivityStatus.local;
  }
  if (networkd.administrative == 'configuring') {
    return NetworkConnectivityStatus.connecting;
  }
  if (networkd.administrative == 'failed' || networkd.online == 'partial') {
    return NetworkConnectivityStatus.limited;
  }
  if (networkd.online == 'online' ||
      networkd.operational == 'routable' ||
      networkd.address == 'routable') {
    return NetworkConnectivityStatus.online;
  }
  if (networkd.operational == 'carrier' || networkd.operational == 'enslaved') {
    return NetworkConnectivityStatus.connecting;
  }
  return NetworkConnectivityStatus.local;
}

WifiSecurity _iwdSecurity(String type) => switch (type) {
  'open' => WifiSecurity.open,
  'wep' => WifiSecurity.wep,
  'psk' => WifiSecurity.wpaPersonal,
  '8021x' => WifiSecurity.enterprise,
  _ => WifiSecurity.unknown,
};

int _signalPercent(int hundredthsDbm) {
  final dbm = hundredthsDbm / 100;
  return ((dbm + 100) * 2).round().clamp(0, 100).toInt();
}

void _validatePassphrase(String value) {
  final hex = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
  if (!hex && (value.length < 8 || value.length > 63)) {
    throw ArgumentError.value(
      value.length,
      'password',
      'Wi-Fi passwords must contain 8–63 characters',
    );
  }
}

int _compareDevices(_IwdDevice left, _IwdDevice right) {
  final leftRank = _deviceRank(left);
  final rightRank = _deviceRank(right);
  final result = rightRank.compareTo(leftRank);
  if (result != 0) {
    return result;
  }
  return left.path.compareTo(right.path);
}

int _deviceRank(_IwdDevice device) => switch (device.state) {
  'connected' => 4,
  'roaming' => 3,
  'connecting' || 'disconnecting' => 2,
  _ when device.powered => 1,
  _ => 0,
};

bool _boolean(Map<String, DBusValue>? properties, String name) {
  final value = properties?[name];
  return value is DBusBoolean && value.value;
}

String _string(
  Map<String, DBusValue>? properties,
  String name, {
  String fallback = '',
}) {
  final value = properties?[name];
  return value is DBusString && value.value.trim().isNotEmpty
      ? value.value.trim()
      : fallback;
}

String? _objectPath(Map<String, DBusValue>? properties, String name) {
  final value = properties?[name];
  return value is DBusObjectPath && value.value != '/' ? value.value : null;
}

List<String> _strings(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusArray && value.signature == DBusSignature('as')
      ? value.asStringArray().toList(growable: false)
      : const <String>[];
}

class _IwdAdapter {
  const _IwdAdapter({
    required this.path,
    required this.powered,
    required this.supportsStation,
  });

  final String path;
  final bool powered;
  final bool supportsStation;
}

class _IwdDevice {
  const _IwdDevice({
    required this.path,
    required this.name,
    required this.mode,
    required this.powered,
    required this.station,
    required this.state,
    required this.connectedNetworkPath,
  });

  final String path;
  final String name;
  final String mode;
  final bool powered;
  final bool station;
  final String state;
  final String? connectedNetworkPath;
}

class _NetworkdLinkState {
  const _NetworkdLinkState({
    required this.operational,
    required this.address,
    required this.online,
    required this.administrative,
  });

  final String operational;
  final String address;
  final String online;
  final String administrative;
}

@visibleForTesting
class IwdAgentEndpoint extends DBusObject {
  IwdAgentEndpoint() : super(DBusObjectPath('/org/denial/IwdAgent'));

  String? Function()? owner;
  String? Function(String networkPath)? passphraseFor;
  VoidCallback? onReleased;

  @override
  List<DBusIntrospectInterface> introspect() => <DBusIntrospectInterface>[
    DBusIntrospectInterface(
      'net.connman.iwd.Agent',
      methods: <DBusIntrospectMethod>[
        DBusIntrospectMethod('Release'),
        DBusIntrospectMethod(
          'RequestPassphrase',
          args: <DBusIntrospectArgument>[
            DBusIntrospectArgument(
              DBusSignature('o'),
              DBusArgumentDirection.in_,
            ),
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.out,
            ),
          ],
        ),
        DBusIntrospectMethod(
          'Cancel',
          args: <DBusIntrospectArgument>[
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
            ),
          ],
        ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != 'net.connman.iwd.Agent') {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final expectedOwner = owner?.call();
    if (expectedOwner == null || methodCall.sender != expectedOwner) {
      return DBusMethodErrorResponse.accessDenied();
    }
    switch (methodCall.name) {
      case 'Release':
        onReleased?.call();
        return DBusMethodSuccessResponse();
      case 'Cancel':
        return DBusMethodSuccessResponse();
      case 'RequestPassphrase':
        if (methodCall.signature != DBusSignature('o')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        final passphrase = passphraseFor?.call(
          methodCall.values.first.asObjectPath().value,
        );
        return passphrase == null
            ? _iwdCanceled('No passphrase is pending for this network')
            : DBusMethodSuccessResponse(<DBusValue>[DBusString(passphrase)]);
      default:
        return _iwdCanceled('This credential request is not supported');
    }
  }
}

DBusMethodErrorResponse _iwdCanceled(String message) => DBusMethodErrorResponse(
  'net.connman.iwd.Agent.Error.Canceled',
  <DBusValue>[DBusString(message)],
);
