import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mobile_network_snapshot.dart';

export 'mobile_network_snapshot.dart';

const modemManagerName = 'org.freedesktop.ModemManager1';
const modemManagerPath = '/org/freedesktop/ModemManager1';
const networkManagerName = 'org.freedesktop.NetworkManager';
const networkManagerPath = '/org/freedesktop/NetworkManager';
const modemInterface = '$modemManagerName.Modem';
const dmailName = 'org.dmail';

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
/// policy and connection profiles. On Phonewave devices dmail replaces both for
/// the modem; whichever of dmail and ModemManager is running is read, dmail
/// first. Never submit a PIN automatically or save it.
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
  bool _published = false;
  bool _dmail = false;
  MobileNetworkSnapshot current = const MobileNetworkSnapshot();
  Stream<MobileNetworkSnapshot> get snapshots => _snapshots.stream;
  static const _timeout = Duration(seconds: 5);

  DBusRemoteObject _object(String name, String path) =>
      DBusRemoteObject(_client, name: name, path: DBusObjectPath(path));
  DBusRemoteObject get _nm => _object(networkManagerName, networkManagerPath);

  static bool _changesWwanSwitches(DBusSignal signal) {
    if (signal.values case [
      DBusString(value: networkManagerName),
      final changed,
      ...,
    ]) {
      return changed is! DBusDict ||
          changed.children.keys.any(
            (name) => name is DBusString && name.value.startsWith('Wwan'),
          );
    }
    return false;
  }

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _subscriptions
      ..add(
        DBusSignalStream(
          _client,
          sender: modemManagerName,
          pathNamespace: DBusObjectPath(modemManagerPath),
        ).listen((_) => _schedule(), onError: (_) => _schedule()),
      )
      // Only the manager's WWAN switches are read from NetworkManager. Its
      // other objects, such as every visible access point, change constantly.
      ..add(
        DBusSignalStream(
              _client,
              sender: networkManagerName,
              interface: 'org.freedesktop.DBus.Properties',
              name: 'PropertiesChanged',
              path: DBusObjectPath(networkManagerPath),
            )
            .where(_changesWwanSwitches)
            .listen((_) => _schedule(), onError: (_) => _schedule()),
      )
      ..add(
        DBusSignalStream(
          _client,
          sender: dmailName,
          interface: 'org.freedesktop.DBus.Properties',
          name: 'PropertiesChanged',
          path: DBusObjectPath(dmailPath),
        ).listen((_) => _schedule(), onError: (_) => _schedule()),
      );
    _subscriptions.add(
      _client.nameOwnerChanged
          .where(
            (event) =>
                event.name == modemManagerName ||
                event.name == networkManagerName ||
                event.name == dmailName,
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
      _dmail = await _client.nameHasOwner(dmailName).timeout(_timeout);
      snapshot = _dmail ? await _readDmail() : await _readModemManager();
    } on Object {
      snapshot = current.unavailable();
    }
    // ModemManager and NetworkManager signal far more often than anything
    // the shell shows changes; an unchanged snapshot wakes no listener once
    // the first one has been published.
    if (!_disposed && (!_published || snapshot != current)) {
      _published = true;
      current = snapshot;
      _snapshots.add(snapshot);
    }
  }

  Future<MobileNetworkSnapshot> _readDmail() async {
    final dmail = _object(dmailName, dmailPath);
    final modem = await dmail
        .getAllProperties('$dmailName.Modem1')
        .timeout(_timeout);
    final data = await dmail
        .getAllProperties('$dmailName.Data1')
        .timeout(_timeout);
    return dmailNetworkSnapshot(
      state: (modem['State'] as DBusString?)?.value ?? 'starting',
      technology: (modem['Technology'] as DBusString?)?.value ?? 'none',
      signal: (modem['Signal'] as DBusByte?)?.value ?? 0,
      operatorName: (modem['Operator'] as DBusString?)?.value ?? '',
      pinRetries: (modem['PinRetries'] as DBusUint32?)?.value ?? 0,
      dataEnabled: (data['Enabled'] as DBusBoolean?)?.value ?? false,
      dataState: (data['State'] as DBusString?)?.value ?? 'off',
      previous: current.modemPath == dmailPath
          ? current.simPresence
          : MobileSimPresence.unknown,
    );
  }

  Future<MobileNetworkSnapshot> _readModemManager() async {
    var nm = <String, DBusValue>{};
    try {
      nm = await _nm.getAllProperties(networkManagerName).timeout(_timeout);
    } on Object {
      /* MM remains useful without NM. */
    }
    // ModemManager is started by systemd when the device has a modem.
    // Activating it from here would retry a failing start job on every
    // refresh; its owner change triggers the read instead.
    final reply = await _object(modemManagerName, modemManagerPath)
        .callMethod(
          'org.freedesktop.DBus.ObjectManager',
          'GetManagedObjects',
          [],
          replySignature: DBusSignature('a{oa{sa{sv}}}'),
          noAutoStart: true,
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
      final slots = (p['SimSlots'] as DBusArray?)?.children
          .map((slot) => slot.asObjectPath().value)
          .toList();
      final failedReason = (p['StateFailedReason'] as DBusUint32?)?.value ?? 0;
      final path = entry.key.asObjectPath().value;
      modems.add(
        MobileNetworkSnapshot(
          modemPath: path,
          simPresence: mobileSimPresence(
            simPath: sim,
            simSlots: slots,
            unlockRequired: lock,
            state: state,
            failedReason: failedReason,
            previous: current.modemPath == path
                ? current.simPresence
                : MobileSimPresence.unknown,
          ),
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
          technology: mobileTechnologyFromModemManager(
            (p['AccessTechnologies'] as DBusUint32?)?.value ?? 0,
          ),
        ),
      );
    }
    return selectMobileNetworkSnapshot(modems, previous: current);
  }

  Future<void> setEnabled(bool enabled) async {
    if (_mutating) throw StateError('Another mobile operation is in progress');
    _mutating = true;
    try {
      await refresh();
      if (!current.canToggle) throw StateError('Mobile data is unavailable');
      if (_dmail) {
        await _object(dmailName, dmailPath)
            .callMethod('$dmailName.Data1', 'SetEnabled', [
              DBusBoolean(enabled),
            ], replySignature: DBusSignature(''))
            .timeout(const Duration(seconds: 25));
      } else {
        await _nm
            .setProperty(
              networkManagerName,
              'WwanEnabled',
              DBusBoolean(enabled),
            )
            .timeout(const Duration(seconds: 25));
      }
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
      final (name, interface, method) = _dmail
          ? (dmailName, '$dmailName.Modem1', 'UnlockPin')
          : (modemManagerName, '$modemManagerName.Sim', 'SendPin');
      await _object(name, simPath)
          .callMethod(interface, method, [
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
