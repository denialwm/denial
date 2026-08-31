import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final batteryNotificationSinkProvider = Provider<BatteryNotificationSink>((
  ref,
) {
  final sink = FreedesktopBatteryNotificationSink();
  ref.onDispose(() => unawaited(sink.close()));
  return sink;
});

@immutable
class BatteryNotification {
  const BatteryNotification({
    required this.threshold,
    required this.capacity,
    required this.summary,
    required this.body,
    required this.critical,
  });

  final int threshold;
  final int capacity;
  final String summary;
  final String body;
  final bool critical;
}

abstract interface class BatteryNotificationSink {
  Future<void> show(BatteryNotification notification);

  Future<void> dismiss();

  Future<void> close();
}

/// Sends shell-owned battery alerts through Denial's freedesktop notification
/// service so they share banner, history, lock-screen, and accessibility
/// behavior with application notifications.
class FreedesktopBatteryNotificationSink implements BatteryNotificationSink {
  FreedesktopBatteryNotificationSink({DBusClient? bus})
    : _bus = bus ?? DBusClient.session() {
    _object = DBusRemoteObject(
      _bus,
      name: _serviceName,
      path: DBusObjectPath(_objectPath),
    );
  }

  static const String _interface = 'org.freedesktop.Notifications';
  static const String _serviceName = 'org.freedesktop.Notifications';
  static const String _objectPath = '/org/freedesktop/Notifications';

  final DBusClient _bus;
  late final DBusRemoteObject _object;
  Future<void> _queue = Future<void>.value();
  int _activeNotificationId = 0;

  @override
  Future<void> show(BatteryNotification notification) {
    return _enqueue(() async {
      final response = await _object.callMethod(
        _interface,
        'Notify',
        <DBusValue>[
          const DBusString('Denial'),
          DBusUint32(_activeNotificationId),
          const DBusString('battery-caution-symbolic'),
          DBusString(notification.summary),
          DBusString(notification.body),
          DBusArray.string(const <String>[]),
          DBusDict.stringVariant(<String, DBusValue>{
            'urgency': DBusByte(notification.critical ? 2 : 1),
            'category': const DBusString('device.battery'),
            'desktop-entry': const DBusString('denial'),
          }),
          DBusInt32(notification.critical ? 0 : 8000),
        ],
        replySignature: DBusSignature('u'),
      );
      _activeNotificationId = response.returnValues.single.asUint32();
    });
  }

  @override
  Future<void> dismiss() {
    return _enqueue(() async {
      final notificationId = _activeNotificationId;
      if (notificationId == 0) {
        return;
      }
      _activeNotificationId = 0;
      try {
        await _object.callMethod(_interface, 'CloseNotification', <DBusValue>[
          DBusUint32(notificationId),
        ], replySignature: DBusSignature(''));
      } on DBusMethodResponseException {
        // A normal-priority alert may already have expired on the server.
      }
    });
  }

  @override
  Future<void> close() async {
    await _queue;
    await _bus.close();
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
