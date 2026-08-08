import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/bluetooth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('managed objects select an adapter, sort devices, and stay bounded', () {
    final managed = <DBusObjectPath, Map<String, Map<String, DBusValue>>>{
      DBusObjectPath('/org/bluez/hci0'): <String, Map<String, DBusValue>>{
        'org.bluez.Adapter1': <String, DBusValue>{
          'Alias': const DBusString('Sleeping adapter'),
          'Powered': const DBusBoolean(false),
          'Discovering': const DBusBoolean(false),
          'Pairable': const DBusBoolean(false),
        },
      },
      DBusObjectPath('/org/bluez/hci1'): <String, Map<String, DBusValue>>{
        'org.bluez.Adapter1': <String, DBusValue>{
          'Alias': const DBusString('Daily adapter'),
          'Powered': const DBusBoolean(true),
          'Discovering': const DBusBoolean(true),
          'Pairable': const DBusBoolean(true),
        },
      },
      for (var index = 0; index < 150; index += 1)
        DBusObjectPath(
          '/org/bluez/hci1/dev_$index',
        ): <String, Map<String, DBusValue>>{
          'org.bluez.Device1': <String, DBusValue>{
            'Adapter': DBusObjectPath('/org/bluez/hci1'),
            'Address': DBusString('00:00:00:00:00:${index % 100}'),
            'Alias': DBusString('Device $index'),
            'Icon': const DBusString('audio-headset'),
            'Connected': DBusBoolean(index == 149),
            'Paired': DBusBoolean(index < 10),
            'Trusted': DBusBoolean(index < 3),
            'Blocked': const DBusBoolean(false),
            'ServicesResolved': DBusBoolean(index == 149),
            'RSSI': DBusInt16(-30 - (index % 50)),
          },
        },
    };

    final snapshot = buildBluetoothSnapshot(managed);

    expect(snapshot.serviceAvailable, isTrue);
    expect(snapshot.available, isTrue);
    expect(snapshot.adapterPath, '/org/bluez/hci1');
    expect(snapshot.adapterName, 'Daily adapter');
    expect(snapshot.powered, isTrue);
    expect(snapshot.discovering, isTrue);
    expect(snapshot.devices, hasLength(128));
    expect(snapshot.devices.first.name, 'Device 149');
    expect(snapshot.devices.first.connected, isTrue);
    expect(
      buildBluetoothSnapshot(managed),
      equals(snapshot),
      reason: 'equivalent signal refreshes must not rebuild consumers',
    );
  });

  test('service without an adapter is represented honestly', () {
    final snapshot = buildBluetoothSnapshot(
      const <DBusObjectPath, Map<String, Map<String, DBusValue>>>{},
    );

    expect(snapshot.serviceAvailable, isTrue);
    expect(snapshot.available, isFalse);
    expect(snapshot.devices, isEmpty);
  });

  test(
    'Agent1 endpoint only accepts calls from the current BlueZ owner',
    () async {
      final endpoint = BluetoothAgentEndpoint();
      endpoint.owner = () => ':1.42';
      var calls = 0;
      endpoint.handler = (call) async {
        calls += 1;
        return DBusMethodSuccessResponse();
      };

      final denied = await endpoint.handleMethodCall(
        DBusMethodCall(
          sender: ':1.99',
          interface: 'org.bluez.Agent1',
          name: 'Cancel',
        ),
      );
      expect(
        (denied as DBusMethodErrorResponse).errorName,
        'org.freedesktop.DBus.Error.AccessDenied',
      );
      expect(calls, 0);

      final accepted = await endpoint.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: 'org.bluez.Agent1',
          name: 'RequestConfirmation',
          values: <DBusValue>[
            DBusObjectPath('/org/bluez/hci0/dev_1'),
            DBusUint32(123456),
          ],
        ),
      );
      expect(accepted, isA<DBusMethodSuccessResponse>());
      expect(calls, 1);

      final interface = endpoint.introspect().single;
      expect(interface.name, 'org.bluez.Agent1');
      expect(
        interface.methods.map((method) => method.name),
        containsAll(<String>[
          'RequestPinCode',
          'RequestPasskey',
          'RequestConfirmation',
          'AuthorizeService',
          'Cancel',
        ]),
      );
    },
  );
}
