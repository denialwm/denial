import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'iwd_service.dart';
import 'network_manager_service.dart';

export 'network_backend.dart';

final networkServiceProvider = Provider<NetworkBackend>((ref) {
  final service = NetworkService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Selects one authoritative Wi-Fi manager for the lifetime of each service
/// owner. NetworkManager wins when both names exist because it may itself be
/// using iwd; direct iwd access is enabled only when NetworkManager is absent.
class NetworkService implements NetworkBackend {
  factory NetworkService({DBusClient? client}) {
    return NetworkService._(client ?? DBusClient.system());
  }

  NetworkService._(this._client);

  static const String _networkManagerName = 'org.freedesktop.NetworkManager';
  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _selectionCoalesce = Duration(milliseconds: 55);

  final DBusClient _client;
  final StreamController<NetworkSnapshot> _snapshots =
      StreamController<NetworkSnapshot>.broadcast(sync: true);

  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerChanges;
  StreamSubscription<NetworkSnapshot>? _backendSnapshots;
  NetworkBackend? _backend;
  String? _backendName;
  Timer? _selectionTimer;
  Future<void> _transition = Future<void>.value();
  NetworkSnapshot _current = const NetworkSnapshot.unavailable();
  bool _started = false;
  bool _disposed = false;

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
    _ownerChanges = _client.nameOwnerChanged
        .where(
          (event) =>
              event.name == _networkManagerName ||
              event.name == IwdService.serviceName,
        )
        .listen((_) => _scheduleSelection());
    await _enqueue(() => _selectBackend(refreshCurrent: false));
  }

  @override
  Future<void> refresh() async {
    if (!_started) {
      await start();
      return;
    }
    await _enqueue(() => _selectBackend(refreshCurrent: true));
  }

  Future<void> _selectBackend({required bool refreshCurrent}) async {
    if (_disposed) {
      return;
    }
    final preferred = await _preferredBackend();
    if (preferred == _backendName) {
      if (refreshCurrent) {
        await _backend?.refresh();
        _emit(_backend?.currentSnapshot ?? const NetworkSnapshot.unavailable());
      }
      return;
    }

    await _backendSnapshots?.cancel();
    _backendSnapshots = null;
    await _backend?.dispose();
    _backend = null;
    _backendName = null;

    if (preferred == null || _disposed) {
      _emit(const NetworkSnapshot.unavailable());
      return;
    }

    final backend = preferred == _networkManagerName
        ? NetworkManagerService()
        : IwdService();
    _backend = backend;
    _backendName = preferred;
    _backendSnapshots = backend.snapshots.listen(_emit);
    try {
      await backend.start();
      _emit(backend.currentSnapshot);
    } on Object {
      await _backendSnapshots?.cancel();
      _backendSnapshots = null;
      await backend.dispose();
      _backend = null;
      _backendName = null;
      _emit(const NetworkSnapshot.unavailable());
    }
  }

  Future<String?> _preferredBackend() async {
    try {
      if (await _client
          .nameHasOwner(_networkManagerName)
          .timeout(_readTimeout)) {
        return _networkManagerName;
      }
      if (await _client
          .nameHasOwner(IwdService.serviceName)
          .timeout(_readTimeout)) {
        return IwdService.serviceName;
      }
    } on Object {
      return null;
    }
    return null;
  }

  void _scheduleSelection() {
    if (_disposed) {
      return;
    }
    _selectionTimer?.cancel();
    _selectionTimer = Timer(_selectionCoalesce, () {
      _selectionTimer = null;
      unawaited(_enqueue(() => _selectBackend(refreshCurrent: true)));
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _transition.then((_) => operation());
    _transition = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<NetworkBackend> _activeBackend() async {
    await _transition;
    final backend = _backend;
    if (backend == null) {
      throw StateError('No supported network service is available');
    }
    return backend;
  }

  @override
  Future<void> setWirelessEnabled(bool enabled) async {
    await (await _activeBackend()).setWirelessEnabled(enabled);
  }

  @override
  Future<void> requestScan() async {
    await (await _activeBackend()).requestScan();
  }

  @override
  Future<void> connect(WifiNetwork network, {String? password}) async {
    await (await _activeBackend()).connect(network, password: password);
  }

  @override
  Future<void> disconnect() async {
    await (await _activeBackend()).disconnect();
  }

  @override
  Future<void> forget(WifiNetwork network) async {
    await (await _activeBackend()).forget(network);
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
    _selectionTimer?.cancel();
    await _ownerChanges?.cancel();
    await _transition;
    await _backendSnapshots?.cancel();
    await _backend?.dispose();
    await _snapshots.close();
    await _client.close();
  }
}
