import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/mobile_network_service.dart';
import 'package:denial_dart_shell/src/services/network_manager_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DBusServer bus;
  late DBusClient owner;
  late MobileNetworkService service;
  late _Modem modem;
  late _Sim sim;
  late _NetworkManager nm;

  setUp(() async {
    bus = DBusServer();
    final address = await bus.listenAddress(
      DBusAddress.unix(dir: Directory.systemTemp),
    );
    owner = DBusClient(address);
    await owner.requestName(modemManagerName);
    await owner.requestName(networkManagerName);
    await owner.registerObject(
      DBusObject(
        DBusObjectPath('/org/freedesktop/ModemManager1'),
        isObjectManager: true,
      ),
    );
    modem = _Modem();
    sim = _Sim(modem);
    nm = _NetworkManager();
    await owner.registerObject(modem);
    await owner.registerObject(sim);
    await owner.registerObject(nm);
    service = MobileNetworkService(client: DBusClient(address));
  });
  tearDown(() async {
    await service.dispose();
    await owner.close();
    await bus.close();
  });

  test(
    'PIN is never sent on discovery and only the current locked SIM can receive it',
    () async {
      await service.start();
      expect(service.current.pinRequired, isTrue);
      expect(service.current.pinRetries, 3);
      expect(sim.calls, 0);
      await expectLater(
        service.sendPin(sim.path.value, '12'),
        throwsArgumentError,
      );
      await expectLater(
        service.sendPin('/org/freedesktop/ModemManager1/SIM/other', '1234'),
        throwsStateError,
      );
      expect(sim.calls, 0);
      await service.sendPin(sim.path.value, '1234');
      expect(sim.calls, 1);
      expect(service.current.pinRequired, isFalse);
      expect(service.current.registered, isTrue);
      expect(service.current.connected, isFalse);
    },
  );

  test(
    'failed PIN refreshes attempts and PUK never receives another PIN',
    () async {
      await service.start();
      sim.fail = true;
      await expectLater(
        service.sendPin(sim.path.value, '1234'),
        throwsA(isA<DBusMethodResponseException>()),
      );
      expect(service.current.pinRetries, 2);
      modem.lock = 4;
      await expectLater(
        service.sendPin(sim.path.value, '1234'),
        throwsStateError,
      );
      expect(sim.calls, 1);
      expect(service.current.pinRequired, isFalse);
      expect(service.current.locked, isTrue);
    },
  );

  test(
    'modem state and signal are authoritative; WWAN changes go only to NM',
    () async {
      modem.lock = 1;
      modem.state = 11;
      await service.start();
      expect(service.current.connected, isTrue);
      expect(service.current.strength, 37);
      await service.setEnabled(false);
      expect(nm.enabled, isFalse);
      expect(nm.writes, 1);
      expect(service.current.enabled, isFalse);
      expect(sim.calls, 0);
      modem.state = 8;
      final update = service.snapshots.firstWhere((s) => !s.connected);
      await modem.emitPropertiesChanged(
        modemInterface,
        changedProperties: {'State': const DBusInt32(8)},
      );
      expect(
        (await update.timeout(const Duration(seconds: 3))).connected,
        isFalse,
      );
      await owner.releaseName(modemManagerName);
      await service.refresh();
      expect(service.current.modemPath, isNull);
    },
  );

  test(
    'PIN2 and PUK2 do not block normal service or accept a primary PIN',
    () async {
      await service.start();
      for (final secondaryLock in [3, 5]) {
        modem.lock = secondaryLock;
        modem.state = 8;
        await service.refresh();
        expect(service.current.registered, isTrue);
        expect(service.current.locked, isFalse);
        expect(service.current.pinRequired, isFalse);
        await expectLater(
          service.sendPin(sim.path.value, '1234'),
          throwsStateError,
        );
      }
      expect(sim.calls, 0);
    },
  );

  test('another online transport does not make disconnected Wi-Fi online', () {
    expect(
      classifyNetworkConnectivity(
        hardwareEnabled: true,
        wirelessEnabled: true,
        managerState: 70,
        connectivity: 4,
        deviceState: 30,
      ),
      NetworkConnectivityStatus.disconnected,
    );
  });
}

class _Modem extends DBusObject {
  _Modem() : super(DBusObjectPath('/org/freedesktop/ModemManager1/Modem/0'));
  int lock = 2;
  int state = 2;
  int retries = 3;
  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    modemInterface: {
      'State': DBusInt32(state),
      'UnlockRequired': DBusUint32(lock),
      'UnlockRetries': DBusDict(DBusSignature('u'), DBusSignature('u'), {
        const DBusUint32(2): DBusUint32(retries),
      }),
      'Sim': DBusObjectPath('/org/freedesktop/ModemManager1/SIM/0'),
      'SignalQuality': DBusStruct([
        const DBusUint32(37),
        const DBusBoolean(true),
      ]),
    },
    '$modemInterface.Modem3gpp': {
      'OperatorName': const DBusString('Test carrier'),
    },
  };
}

class _Sim extends DBusObject {
  _Sim(this.modem)
    : super(DBusObjectPath('/org/freedesktop/ModemManager1/SIM/0'));
  final _Modem modem;
  int calls = 0;
  bool fail = false;
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != '$modemManagerName.Sim' || call.name != 'SendPin') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    calls++;
    if (fail) {
      modem.retries--;
      return DBusMethodErrorResponse(
        '$modemManagerName.Error.MobileEquipment.IncorrectPassword',
      );
    }
    modem.lock = 1;
    modem.state = 8;
    return DBusMethodSuccessResponse([]);
  }
}

class _NetworkManager extends DBusObject {
  _NetworkManager() : super(DBusObjectPath('/org/freedesktop/NetworkManager'));
  bool enabled = true;
  int writes = 0;
  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        'WwanEnabled': DBusBoolean(enabled),
        'WwanHardwareEnabled': const DBusBoolean(true),
      });
  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    expect(interface, networkManagerName);
    expect(name, 'WwanEnabled');
    enabled = value.asBoolean();
    writes++;
    return DBusMethodSuccessResponse([]);
  }
}
