import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'bluetooth_service_agent.dart';
part 'bluetooth_service_models.dart';

final bluetoothServiceProvider = Provider<BluetoothBackend>((ref) {
  final service = BluetoothService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// BlueZ integration over one persistent system-bus connection.
///
/// ObjectManager and property signals are coalesced into bounded immutable
/// snapshots. There is no radio polling and no `bluetoothctl` process. The
/// registered Agent1 object turns BlueZ's asynchronous pairing conversations
/// into a single bounded UI request with a hard timeout.
class BluetoothService implements BluetoothBackend {
  factory BluetoothService({DBusClient? client}) {
    return BluetoothService._(client ?? DBusClient.system());
  }

  BluetoothService._(this._client)
    : _manager = DBusRemoteObjectManager(
        _client,
        name: _bluez,
        path: DBusObjectPath.root,
      ),
      _agent = BluetoothAgentEndpoint();

  static const String _bluez = 'org.bluez';
  static const String _adapterInterface = 'org.bluez.Adapter1';
  static const String _deviceInterface = 'org.bluez.Device1';
  static const String _agentManagerInterface = 'org.bluez.AgentManager1';
  static const String _agentPath = '/org/denial/BluetoothAgent';
  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _methodTimeout = Duration(seconds: 25);
  static const Duration _agentTimeout = Duration(seconds: 60);
  static const Duration _signalCoalesce = Duration(milliseconds: 55);
  static const int _maxAdapters = 4;
  static const int _maxDevices = 128;

  final DBusClient _client;
  final DBusRemoteObjectManager _manager;
  final BluetoothAgentEndpoint _agent;
  final StreamController<BluetoothSnapshot> _snapshots =
      StreamController<BluetoothSnapshot>.broadcast(sync: true);
  final StreamController<BluetoothPairingRequest?> _pairingRequests =
      StreamController<BluetoothPairingRequest?>.broadcast(sync: true);

  StreamSubscription<DBusSignal>? _signalSubscription;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerSubscription;
  Timer? _refreshTimer;
  Timer? _pairingTimer;
  Timer? _displayTimer;
  _PendingPairing? _pendingPairing;
  BluetoothPairingRequest? _currentPairingRequest;
  BluetoothSnapshot _current = const BluetoothSnapshot.unavailable();
  String? _bluezOwner;
  bool _started = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _agentRegistered = false;
  int _nextPairingId = 1;

  @override
  Stream<BluetoothSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<BluetoothPairingRequest?> get pairingRequests =>
      _pairingRequests.stream;

  @override
  BluetoothSnapshot get currentSnapshot => _current;

  @override
  BluetoothPairingRequest? get currentPairingRequest => _currentPairingRequest;

  @override
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _agent.owner = () => _bluezOwner;
    _agent.handler = _handleAgentMethod;
    await _client.registerObject(_agent);
    _signalSubscription = _manager.signals.listen(
      _handleBluezSignal,
      onError: (_) => _scheduleRefresh(),
    );
    _ownerSubscription = _client.nameOwnerChanged
        .where((event) => event.name == _bluez)
        .listen(_handleOwnerChanged);
    _bluezOwner = await _client.getNameOwner(_bluez).timeout(_readTimeout);
    if (_bluezOwner != null) {
      try {
        await _registerAgent();
      } on Object {
        // Adapter status and existing connections remain authoritative even
        // when system policy does not permit Denial to become the agent.
      }
    }
    await refresh();
  }

  void _handleBluezSignal(DBusSignal signal) {
    if (signal is DBusPropertiesChangedSignal) {
      final interface = signal.propertiesInterface;
      if (interface != _adapterInterface && interface != _deviceInterface) {
        return;
      }
    } else if (signal is DBusObjectManagerInterfacesAddedSignal) {
      final interfaces = signal.interfacesAndProperties.keys;
      if (!interfaces.contains(_adapterInterface) &&
          !interfaces.contains(_deviceInterface)) {
        return;
      }
    } else if (signal is DBusObjectManagerInterfacesRemovedSignal) {
      if (!signal.interfaces.contains(_adapterInterface) &&
          !signal.interfaces.contains(_deviceInterface)) {
        return;
      }
    } else {
      return;
    }
    _scheduleRefresh();
  }

  void _handleOwnerChanged(DBusNameOwnerChangedEvent event) {
    _bluezOwner = event.newOwner;
    _agentRegistered = false;
    if (event.newOwner == null) {
      _refreshTimer?.cancel();
      _cancelPairing('Bluetooth service stopped');
      _emit(const BluetoothSnapshot.unavailable());
      return;
    }
    unawaited(_recoverService());
  }

  Future<void> _recoverService() async {
    try {
      await _registerAgent();
    } on Object {
      // The adapter remains usable even if another policy agent wins. Pairing
      // failures are surfaced when the user actually requests them.
    }
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
        _emit(const BluetoothSnapshot.unavailable());
      }
    } finally {
      _refreshing = false;
      if (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        _scheduleRefresh(immediate: true);
      }
    }
  }

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

  void _emit(BluetoothSnapshot snapshot) {
    if (snapshot == _current) {
      return;
    }
    _current = snapshot;
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
  }

  Future<BluetoothSnapshot> _readSnapshot() async {
    final owner =
        _bluezOwner ?? await _client.getNameOwner(_bluez).timeout(_readTimeout);
    if (owner == null) {
      return const BluetoothSnapshot.unavailable();
    }
    _bluezOwner = owner;
    final managed = await _manager.getManagedObjects().timeout(_readTimeout);
    return buildBluetoothSnapshot(
      managed,
      maxAdapters: _maxAdapters,
      maxDevices: _maxDevices,
    );
  }

  @override
  Future<void> setPowered(bool powered) async {
    final adapter = await _adapter();
    await adapter
        .setProperty(_adapterInterface, 'Powered', DBusBoolean(powered))
        .timeout(_methodTimeout);
    await refresh();
  }

  @override
  Future<void> startDiscovery() async {
    final adapter = await _adapter();
    try {
      await adapter
          .callMethod(
            _adapterInterface,
            'SetDiscoveryFilter',
            <DBusValue>[
              DBusDict.stringVariant(const <String, DBusValue>{
                'Transport': DBusString('auto'),
                'DuplicateData': DBusBoolean(false),
              }),
            ],
            replySignature: DBusSignature(''),
          )
          .timeout(_methodTimeout);
    } on DBusMethodResponseException catch (error) {
      if (error.errorName != 'org.freedesktop.DBus.Error.UnknownMethod' &&
          error.errorName != 'org.bluez.Error.NotSupported') {
        rethrow;
      }
      // Older BlueZ releases may not expose discovery filters.
    }
    if (!_current.discovering) {
      await adapter
          .callMethod(
            _adapterInterface,
            'StartDiscovery',
            const <DBusValue>[],
            replySignature: DBusSignature(''),
          )
          .timeout(_methodTimeout);
    }
    await refresh();
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_current.available || !_current.discovering) {
      return;
    }
    try {
      await (await _adapter())
          .callMethod(
            _adapterInterface,
            'StopDiscovery',
            const <DBusValue>[],
            replySignature: DBusSignature(''),
          )
          .timeout(_methodTimeout);
    } on DBusMethodResponseException catch (error) {
      if (error.errorName != 'org.bluez.Error.NotReady' &&
          error.errorName != 'org.bluez.Error.Failed') {
        rethrow;
      }
    }
    await refresh();
  }

  @override
  Future<void> pair(BluetoothDeviceInfo device) async {
    await _ensureAgent();
    await _device(device)
        .callMethod(
          _deviceInterface,
          'Pair',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout + _agentTimeout);
    await refresh();
  }

  @override
  Future<void> setTrusted(BluetoothDeviceInfo device, bool trusted) async {
    await _device(device)
        .setProperty(_deviceInterface, 'Trusted', DBusBoolean(trusted))
        .timeout(_methodTimeout);
    await refresh();
  }

  @override
  Future<void> connect(BluetoothDeviceInfo device) async {
    await _device(device)
        .callMethod(
          _deviceInterface,
          'Connect',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
    await refresh();
  }

  @override
  Future<void> disconnect(BluetoothDeviceInfo device) async {
    await _device(device)
        .callMethod(
          _deviceInterface,
          'Disconnect',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
    await refresh();
  }

  @override
  Future<void> remove(BluetoothDeviceInfo device) async {
    if (_currentPairingRequest?.devicePath == device.objectPath) {
      respondToPairing(_currentPairingRequest!.id, accepted: false);
    }
    await (await _adapter())
        .callMethod(_adapterInterface, 'RemoveDevice', <DBusValue>[
          DBusObjectPath(device.objectPath),
        ], replySignature: DBusSignature(''))
        .timeout(_methodTimeout);
    await refresh();
  }

  Future<void> _ensureAgent() async {
    if (_agentRegistered) {
      return;
    }
    await _registerAgent();
    if (!_agentRegistered) {
      throw StateError('Bluetooth pairing agent is unavailable');
    }
  }

  Future<void> _registerAgent() async {
    if (_disposed || _bluezOwner == null || _agentRegistered) {
      return;
    }
    final manager = DBusRemoteObject(
      _client,
      name: _bluez,
      path: DBusObjectPath('/org/bluez'),
    );
    try {
      await manager
          .callMethod(
            _agentManagerInterface,
            'RegisterAgent',
            <DBusValue>[
              DBusObjectPath(_agentPath),
              const DBusString('KeyboardDisplay'),
            ],
            replySignature: DBusSignature(''),
          )
          .timeout(_readTimeout);
    } on DBusMethodResponseException catch (error) {
      if (error.errorName != 'org.bluez.Error.AlreadyExists') {
        rethrow;
      }
    }
    await manager
        .callMethod(
          _agentManagerInterface,
          'RequestDefaultAgent',
          <DBusValue>[DBusObjectPath(_agentPath)],
          replySignature: DBusSignature(''),
        )
        .timeout(_readTimeout);
    _agentRegistered = true;
  }

  Future<DBusMethodResponse> _handleAgentMethod(
    DBusMethodCall methodCall,
  ) async {
    final values = methodCall.values;
    switch (methodCall.name) {
      case 'Release':
        _agentRegistered = false;
        _cancelPairing('Bluetooth pairing agent was released');
        return DBusMethodSuccessResponse();
      case 'Cancel':
        _cancelPairing('Bluetooth pairing was cancelled');
        return DBusMethodSuccessResponse();
      case 'RequestPinCode':
        if (methodCall.signature != DBusSignature('o')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        return _requestPairing(
          kind: BluetoothPairingRequestKind.pinCode,
          devicePath: values[0].asObjectPath().value,
        );
      case 'RequestPasskey':
        if (methodCall.signature != DBusSignature('o')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        return _requestPairing(
          kind: BluetoothPairingRequestKind.passkey,
          devicePath: values[0].asObjectPath().value,
        );
      case 'RequestConfirmation':
        if (methodCall.signature != DBusSignature('ou')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        return _requestPairing(
          kind: BluetoothPairingRequestKind.confirmation,
          devicePath: values[0].asObjectPath().value,
          passkey: values[1].asUint32(),
        );
      case 'RequestAuthorization':
        if (methodCall.signature != DBusSignature('o')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        return _requestPairing(
          kind: BluetoothPairingRequestKind.authorization,
          devicePath: values[0].asObjectPath().value,
        );
      case 'AuthorizeService':
        if (methodCall.signature != DBusSignature('os')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        return _requestPairing(
          kind: BluetoothPairingRequestKind.serviceAuthorization,
          devicePath: values[0].asObjectPath().value,
          serviceUuid: _bounded(values[1].asString(), 64),
        );
      case 'DisplayPinCode':
        if (methodCall.signature != DBusSignature('os')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        _displayPairing(
          kind: BluetoothPairingRequestKind.displayPinCode,
          devicePath: values[0].asObjectPath().value,
          displayValue: _bounded(values[1].asString(), 16),
        );
        return DBusMethodSuccessResponse();
      case 'DisplayPasskey':
        if (methodCall.signature != DBusSignature('ouq')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        _displayPairing(
          kind: BluetoothPairingRequestKind.displayPasskey,
          devicePath: values[0].asObjectPath().value,
          passkey: values[1].asUint32(),
          enteredDigits: values[2].asUint16().clamp(0, 6).toInt(),
        );
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  Future<DBusMethodResponse> _requestPairing({
    required BluetoothPairingRequestKind kind,
    required String devicePath,
    int? passkey,
    String? serviceUuid,
  }) {
    _cancelPairing('A newer Bluetooth pairing request replaced this one');
    final request = _newPairingRequest(
      kind: kind,
      devicePath: devicePath,
      passkey: passkey,
      serviceUuid: serviceUuid,
    );
    final completer = Completer<DBusMethodResponse>();
    _pendingPairing = _PendingPairing(request, completer);
    _publishPairing(request);
    _pairingTimer = Timer(_agentTimeout, () {
      if (_pendingPairing?.request.id == request.id) {
        _cancelPairing('Bluetooth pairing confirmation timed out');
      }
    });
    return completer.future;
  }

  void _displayPairing({
    required BluetoothPairingRequestKind kind,
    required String devicePath,
    String? displayValue,
    int? passkey,
    int enteredDigits = 0,
  }) {
    if (_pendingPairing != null) {
      return;
    }
    final parsedPasskey = displayValue == null
        ? passkey
        : int.tryParse(displayValue.padLeft(6, '0'));
    final request = _newPairingRequest(
      kind: kind,
      devicePath: devicePath,
      passkey: parsedPasskey,
      pinCode: displayValue,
      enteredDigits: enteredDigits,
    );
    _publishPairing(request);
    _displayTimer?.cancel();
    _displayTimer = Timer(_agentTimeout, () {
      if (_currentPairingRequest?.id == request.id && _pendingPairing == null) {
        _publishPairing(null);
      }
    });
  }

  BluetoothPairingRequest _newPairingRequest({
    required BluetoothPairingRequestKind kind,
    required String devicePath,
    int? passkey,
    String? pinCode,
    int enteredDigits = 0,
    String? serviceUuid,
  }) {
    final device = _current.deviceAt(devicePath);
    final id = _nextPairingId;
    _nextPairingId = id >= 0x7fffffff ? 1 : id + 1;
    return BluetoothPairingRequest(
      id: id,
      kind: kind,
      devicePath: devicePath,
      address: device?.address ?? '',
      deviceName: device?.name ?? 'Bluetooth device',
      passkey: passkey,
      pinCode: pinCode,
      enteredDigits: enteredDigits,
      serviceUuid: serviceUuid,
    );
  }

  @override
  void respondToPairing(
    int requestId, {
    required bool accepted,
    String? response,
  }) {
    final pending = _pendingPairing;
    if (pending == null || pending.request.id != requestId) {
      return;
    }
    _pendingPairing = null;
    _pairingTimer?.cancel();
    _pairingTimer = null;
    _publishPairing(null);
    if (!accepted) {
      pending.completer.complete(_bluezRejected('Pairing rejected'));
      return;
    }

    final kind = pending.request.kind;
    if (kind == BluetoothPairingRequestKind.pinCode) {
      final pin = response ?? '';
      if (pin.isEmpty ||
          pin.length > 16 ||
          !RegExp(r'^[\x20-\x7e]+$').hasMatch(pin)) {
        pending.completer.complete(_bluezRejected('Invalid PIN code'));
        return;
      }
      pending.completer.complete(
        DBusMethodSuccessResponse(<DBusValue>[DBusString(pin)]),
      );
      return;
    }
    if (kind == BluetoothPairingRequestKind.passkey) {
      final passkey = int.tryParse(response ?? '');
      if (passkey == null || passkey < 0 || passkey > 999999) {
        pending.completer.complete(_bluezRejected('Invalid passkey'));
        return;
      }
      pending.completer.complete(
        DBusMethodSuccessResponse(<DBusValue>[DBusUint32(passkey)]),
      );
      return;
    }
    pending.completer.complete(DBusMethodSuccessResponse());
  }

  void _cancelPairing(String reason) {
    _pairingTimer?.cancel();
    _pairingTimer = null;
    _displayTimer?.cancel();
    _displayTimer = null;
    final pending = _pendingPairing;
    _pendingPairing = null;
    _publishPairing(null);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(_bluezCanceled(reason));
    }
  }

  void _publishPairing(BluetoothPairingRequest? request) {
    _currentPairingRequest = request;
    if (!_pairingRequests.isClosed) {
      _pairingRequests.add(request);
    }
  }

  Future<DBusRemoteObject> _adapter() async {
    if (!_current.available || _current.adapterPath == null) {
      await refresh();
    }
    final path = _current.adapterPath;
    if (path == null) {
      throw StateError('No Bluetooth adapter is available');
    }
    return DBusRemoteObject(_client, name: _bluez, path: DBusObjectPath(path));
  }

  DBusRemoteObject _device(BluetoothDeviceInfo device) {
    return DBusRemoteObject(
      _client,
      name: _bluez,
      path: DBusObjectPath(device.objectPath),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _refreshTimer?.cancel();
    _cancelPairing('Bluetooth integration stopped');
    await _signalSubscription?.cancel();
    await _ownerSubscription?.cancel();
    try {
      await _client.unregisterObject(_agent);
    } on Object {
      // Closing the private connection also unregisters the object.
    }
    await _snapshots.close();
    await _pairingRequests.close();
    await _client.close();
  }
}

@visibleForTesting
BluetoothSnapshot buildBluetoothSnapshot(
  Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> managed, {
  int maxAdapters = 4,
  int maxDevices = 128,
}) {
  final adapters = <_AdapterSnapshot>[];
  for (final entry in managed.entries) {
    final properties = entry.value['org.bluez.Adapter1'];
    if (properties == null) {
      continue;
    }
    final candidate = _AdapterSnapshot(
      path: entry.key.value,
      name: _bounded(
        _string(properties, 'Alias', fallback: _string(properties, 'Name')),
        96,
      ),
      powered: _boolean(properties, 'Powered'),
      discovering: _boolean(properties, 'Discovering'),
      pairable: _boolean(properties, 'Pairable'),
    );
    if (adapters.length < maxAdapters) {
      adapters.add(candidate);
    } else {
      final replace = adapters.indexWhere((adapter) => !adapter.powered);
      if (candidate.powered && replace >= 0) {
        adapters[replace] = candidate;
      }
    }
  }
  if (adapters.isEmpty) {
    return const BluetoothSnapshot(
      serviceAvailable: true,
      available: false,
      adapterPath: null,
      adapterName: '',
      powered: false,
      discovering: false,
      pairable: false,
      devices: <BluetoothDeviceInfo>[],
    );
  }
  adapters.sort((left, right) {
    final powered = _compareTrueFirst(left.powered, right.powered);
    return powered != 0 ? powered : left.path.compareTo(right.path);
  });
  final adapter = adapters.first;
  final devices = <BluetoothDeviceInfo>[];
  for (final entry in managed.entries) {
    final properties = entry.value['org.bluez.Device1'];
    if (properties == null ||
        _objectPath(properties, 'Adapter') != adapter.path) {
      continue;
    }
    final address = _bounded(_string(properties, 'Address'), 32);
    final name = _bounded(
      _string(
        properties,
        'Alias',
        fallback: _string(properties, 'Name', fallback: address),
      ),
      96,
    );
    final candidate = BluetoothDeviceInfo(
      objectPath: entry.key.value,
      adapterPath: adapter.path,
      address: address,
      name: name.isEmpty ? 'Unknown device' : name,
      icon: _bounded(_string(properties, 'Icon'), 64),
      connected: _boolean(properties, 'Connected'),
      paired: _boolean(properties, 'Paired') || _boolean(properties, 'Bonded'),
      trusted: _boolean(properties, 'Trusted'),
      blocked: _boolean(properties, 'Blocked'),
      servicesResolved: _boolean(properties, 'ServicesResolved'),
      signalStrength: _int16(properties, 'RSSI'),
    );
    if (devices.length < maxDevices) {
      devices.add(candidate);
    } else if (devices.isNotEmpty) {
      var worstIndex = 0;
      for (var index = 1; index < devices.length; index += 1) {
        if (_compareBluetoothDevices(devices[worstIndex], devices[index]) < 0) {
          worstIndex = index;
        }
      }
      if (_compareBluetoothDevices(candidate, devices[worstIndex]) < 0) {
        devices[worstIndex] = candidate;
      }
    }
  }
  devices.sort(_compareBluetoothDevices);
  return BluetoothSnapshot(
    serviceAvailable: true,
    available: true,
    adapterPath: adapter.path,
    adapterName: adapter.name,
    powered: adapter.powered,
    discovering: adapter.discovering,
    pairable: adapter.pairable,
    devices: List<BluetoothDeviceInfo>.unmodifiable(devices),
  );
}
