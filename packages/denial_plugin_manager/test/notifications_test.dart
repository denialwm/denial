import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:test/test.dart';

/// Records Notify calls the way Denial's notification server receives them.
final class FakeServer extends DBusObject {
  FakeServer() : super(DBusObjectPath('/org/freedesktop/Notifications'));
  final calls = <List<DBusValue>>[];
  final closed = <int>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    switch (call.name) {
      case 'GetCapabilities':
        return DBusMethodSuccessResponse([
          DBusArray.string(['actions', 'body']),
        ]);
      case 'Notify':
        calls.add(call.values);
        final replaces = call.values[1].asUint32();
        return DBusMethodSuccessResponse([
          DBusUint32(replaces == 0 ? calls.length : replaces),
        ]);
      case 'CloseNotification':
        closed.add(call.values.single.asUint32());
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  Process? daemon;
  String? address;
  setUpAll(() async {
    try {
      daemon = await Process.start('dbus-daemon', [
        '--session',
        '--nofork',
        '--print-address',
      ]);
      address =
          (await daemon!.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .first)
              .trim();
    } on ProcessException {
      daemon = null;
    }
  });
  tearDownAll(() => daemon?.kill());

  test(
    'notifications carry their actions, hints and activation tokens',
    () async {
      final server = DBusClient(DBusAddress(address!));
      final fake = FakeServer();
      // The client starts first, like denial-plugins resume before deniald's
      // event loop owns the service, and must wait instead of failing.
      final connecting = DesktopNotifications.connect(
        client: DBusClient(DBusAddress(address!)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await server.registerObject(fake);
      await server.requestName('org.freedesktop.Notifications');
      final notifications = await connecting;
      final events = <NotificationEvent>[];
      final subscription = notifications.events.listen(events.add);
      try {
        final id = await notifications.show(
          const NotificationContent(
            title: 'Bringing back your plugins',
            body: 'Your plugins and their settings are safe.',
            actions: [('open', 'Open Plugins'), ('default', 'Open Plugins')],
            resident: true,
            persistent: true,
          ),
        );
        expect(id, 1);
        final call = fake.calls.single;
        expect(call[0].asString(), 'Plugins');
        expect(call[3].asString(), 'Bringing back your plugins');
        expect(call[5].asStringArray(), [
          'open',
          'Open Plugins',
          'default',
          'Open Plugins',
        ]);
        final hints = call[6].asStringVariantDict();
        expect(hints['desktop-entry']!.asString(), 'org.denialwm.Settings');
        expect(hints['resident']!.asBoolean(), isTrue);
        expect(call[7].asInt32(), 0);

        expect(
          await notifications.show(
            const NotificationContent(title: 'Your plugins are back', body: ''),
            replaces: id,
          ),
          id,
        );
        expect(fake.calls.last[7].asInt32(), -1);

        // Denial announces the token just before the action it belongs to.
        await fake.emitSignal(
          'org.freedesktop.Notifications',
          'ActivationToken',
          [DBusUint32(id), const DBusString('token')],
        );
        await fake.emitSignal(
          'org.freedesktop.Notifications',
          'ActionInvoked',
          [DBusUint32(id), const DBusString('open')],
        );
        await fake.emitSignal(
          'org.freedesktop.Notifications',
          'NotificationClosed',
          [DBusUint32(id), DBusUint32(2)],
        );
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (events.length < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final action = events.first as NotificationActionInvoked;
        expect(
          (action.id, action.key, action.activationToken),
          (id, 'open', 'token'),
        );
        expect(events.last, isA<NotificationClosed>());
        await notifications.close(id);
        expect(fake.closed, [id]);
      } finally {
        await subscription.cancel();
        await notifications.dispose();
        await server.close();
      }
    },
    skip: Process.runSync('sh', ['-c', 'command -v dbus-daemon']).exitCode == 0
        ? false
        : 'dbus-daemon is not installed',
  );
}
