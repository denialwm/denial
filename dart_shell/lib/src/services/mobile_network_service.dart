import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const modemManagerName = 'org.freedesktop.ModemManager1';
const networkManagerName = 'org.freedesktop.NetworkManager';
const modemInterface = '$modemManagerName.Modem';

class MobileNetworkSnapshot {
  const MobileNetworkSnapshot({
    this.modemPath,
    this.simPath,
    this.unlockRequired = 0,
    this.pinRetries,
    this.strength = 0,
    this.registered = false,
    this.connected = false,
    this.enabled = false,
    this.hardwareEnabled = false,
    this.managerAvailable = false,
    this.operatorName = '',
  });

  final String? modemPath;
  final String? simPath;
  final int unlockRequired;
  final int? pinRetries;
  final int strength;
  final bool registered;
  final bool connected;
  final bool enabled;
  final bool hardwareEnabled;
  final bool managerAvailable;
  final String operatorName;
  bool get pinRequired => unlockRequired == 2 && simPath != null;
  // PIN2/PUK2 protect supplementary SIM functions, not normal modem use.
  // ModemManager permits initialization and registration with these locks.
  bool get locked =>
      unlockRequired > 1 && unlockRequired != 3 && unlockRequired != 5;
  bool get canToggle =>
      managerAvailable && hardwareEnabled && modemPath != null;
}

final mobileNetworkServiceProvider = Provider<MobileNetworkService>((ref) {
  final service = MobileNetworkService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final mobileNetworkProvider = StreamProvider<MobileNetworkSnapshot>((ref) {
  final service = ref.watch(mobileNetworkServiceProvider);
  unawaited(service.start());
  return service.snapshots;
});

/// ModemManager owns SIM and registration state; NetworkManager owns WWAN
/// policy and connection profiles. Never submit a PIN automatically or save it.
class MobileNetworkService {
  MobileNetworkService({DBusClient? client})
    : _client = client ?? DBusClient.system();
  final DBusClient _client;
  final _snapshots = StreamController<MobileNetworkSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _again = false;
  Future<void>? _reading;
  bool _mutating = false;
  MobileNetworkSnapshot current = const MobileNetworkSnapshot();
  Stream<MobileNetworkSnapshot> get snapshots => _snapshots.stream;
  static const _timeout = Duration(seconds: 5);

  DBusRemoteObject _object(String name, String path) =>
      DBusRemoteObject(_client, name: name, path: DBusObjectPath(path));
  DBusRemoteObject get _nm =>
      _object(networkManagerName, '/org/freedesktop/NetworkManager');

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    for (final name in [modemManagerName, networkManagerName]) {
      _subscriptions.add(
        DBusSignalStream(
          _client,
          sender: name,
          pathNamespace: DBusObjectPath('/${name.replaceAll('.', '/')}'),
        ).listen((_) => _schedule(), onError: (_) => _schedule()),
      );
    }
    _subscriptions.add(
      _client.nameOwnerChanged
          .where(
            (event) =>
                event.name == modemManagerName ||
                event.name == networkManagerName,
          )
          .listen((_) => _schedule()),
    );
    await refresh();
  }

  void _schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 80),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_reading != null) {
      _again = true;
      return _reading!;
    }
    return _reading = _refresh().whenComplete(() {
      _reading = null;
      if (_again) {
        _again = false;
        _schedule();
      }
    });
  }

  Future<void> _refresh() async {
    MobileNetworkSnapshot snapshot;
    try {
      var nm = <String, DBusValue>{};
      try {
        nm = await _nm.getAllProperties(networkManagerName).timeout(_timeout);
      } on Object {
        /* MM remains useful without NM. */
      }
      final reply =
          await _object(modemManagerName, '/org/freedesktop/ModemManager1')
              .callMethod(
                'org.freedesktop.DBus.ObjectManager',
                'GetManagedObjects',
                [],
                replySignature: DBusSignature('a{oa{sa{sv}}}'),
              )
              .timeout(_timeout);
      final modems = <MobileNetworkSnapshot>[];
      for (final entry in reply.returnValues.single.asDict().entries) {
        final interfaces = entry.value.asDict();
        final raw = interfaces[const DBusString(modemInterface)];
        if (raw == null) continue;
        final p = raw.asStringVariantDict();
        final gsm =
            interfaces[const DBusString('$modemInterface.Modem3gpp')]
                ?.asStringVariantDict() ??
            {};
        final state = (p['State'] as DBusInt32?)?.value ?? 0;
        final quality = (p['SignalQuality'] as DBusStruct?)?.children;
        final lock = (p['UnlockRequired'] as DBusUint32?)?.value ?? 0;
        final retries =
            (p['UnlockRetries'] as DBusDict?)?.children[DBusUint32(lock)];
        final sim = (p['Sim'] as DBusObjectPath?)?.value;
        modems.add(
          MobileNetworkSnapshot(
            modemPath: entry.key.asObjectPath().value,
            simPath: sim == '/' ? null : sim,
            unlockRequired: lock,
            pinRetries: retries is DBusUint32 ? retries.value : null,
            strength: quality == null
                ? 0
                : quality.first.asUint32().clamp(0, 100),
            registered: state >= 8,
            connected: state == 11,
            enabled: (nm['WwanEnabled'] as DBusBoolean?)?.value ?? false,
            hardwareEnabled:
                (nm['WwanHardwareEnabled'] as DBusBoolean?)?.value ?? false,
            managerAvailable: nm.isNotEmpty,
            operatorName: (gsm['OperatorName'] as DBusString?)?.value ?? '',
          ),
        );
      }
      // A locked SIM takes priority so every pending PIN can be handled. Once
      // unlocked, prefer a connected modem, then stable object-path ordering.
      modems.sort((a, b) {
        int rank(MobileNetworkSnapshot s) => s.pinRequired
            ? 3
            : s.connected
            ? 2
            : s.registered
            ? 1
            : 0;
        final order = rank(b).compareTo(rank(a));
        return order != 0 ? order : a.modemPath!.compareTo(b.modemPath!);
      });
      snapshot = modems.firstOrNull ?? const MobileNetworkSnapshot();
    } on Object {
      snapshot = const MobileNetworkSnapshot();
    }
    if (!_disposed) {
      current = snapshot;
      _snapshots.add(snapshot);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (_mutating) throw StateError('Another mobile operation is in progress');
    _mutating = true;
    try {
      await refresh();
      if (!current.canToggle) throw StateError('Mobile data is unavailable');
      await _nm
          .setProperty(networkManagerName, 'WwanEnabled', DBusBoolean(enabled))
          .timeout(const Duration(seconds: 25));
    } finally {
      await refresh();
      _mutating = false;
    }
  }

  Future<void> sendPin(String simPath, String pin) async {
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(pin)) {
      throw ArgumentError('PIN must contain 4–8 digits');
    }
    if (_mutating) throw StateError('Another mobile operation is in progress');
    _mutating = true;
    try {
      await refresh();
      if (!current.pinRequired ||
          current.simPath != simPath ||
          current.pinRetries == 0) {
        throw StateError('SIM lock state changed');
      }
      await _object(modemManagerName, simPath)
          .callMethod('$modemManagerName.Sim', 'SendPin', [
            DBusString(pin),
          ], replySignature: DBusSignature(''))
          .timeout(const Duration(seconds: 25));
    } finally {
      await refresh();
      _mutating = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _client.close();
    await _snapshots.close();
  }
}
