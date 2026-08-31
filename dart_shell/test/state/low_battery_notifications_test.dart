import 'package:denial_dart_shell/src/models/battery_status.dart';
import 'package:denial_dart_shell/src/services/battery_notification_service.dart';
import 'package:denial_dart_shell/src/state/low_battery_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const copy = LowBatteryNotificationCopy(
    lowTitle: 'Low battery',
    criticalTitle: 'Critical battery',
    body: _body,
  );

  test(
    'publishes each requested threshold once with escalating urgency',
    () async {
      final sink = _FakeBatteryNotificationSink();
      final coordinator = LowBatteryNotificationCoordinator(sink);

      for (final capacity in <int>[21, 20, 19, 15, 10, 5, 1, 0]) {
        await coordinator.update(_status(capacity), copy: copy);
      }

      expect(
        sink.notifications.map((notification) => notification.threshold),
        <int>[20, 15, 10, 5, 1],
      );
      expect(
        sink.notifications.map((notification) => notification.critical),
        <bool>[false, false, true, true, true],
      );
      expect(sink.notifications[2].summary, 'Critical battery');
      expect(
        sink.notifications[2].body,
        'Battery is at 10%. Connect a charger.',
      );
    },
  );

  test('uses the nearest crossed threshold when a poll skips it', () async {
    final sink = _FakeBatteryNotificationSink();
    final coordinator = LowBatteryNotificationCoordinator(sink);

    await coordinator.update(_status(14), copy: copy);
    await coordinator.update(_status(9), copy: copy);

    expect(
      sink.notifications.map(
        (notification) => (notification.threshold, notification.capacity),
      ),
      <(int, int)>[(15, 14), (10, 9)],
    );
  });

  test(
    'charging dismisses the alert without immediately repeating it',
    () async {
      final sink = _FakeBatteryNotificationSink();
      final coordinator = LowBatteryNotificationCoordinator(sink);

      await coordinator.update(_status(10), copy: copy);
      await coordinator.update(_status(10, charging: true), copy: copy);
      await coordinator.update(_status(10), copy: copy);

      expect(sink.dismissals, 1);
      expect(sink.notifications, hasLength(1));

      await coordinator.update(_status(11, charging: true), copy: copy);
      await coordinator.update(_status(10), copy: copy);

      expect(sink.notifications, hasLength(2));
    },
  );
}

String _body(int capacity) => 'Battery is at $capacity%. Connect a charger.';

BatteryStatus _status(int capacity, {bool charging = false}) =>
    BatteryStatus(capacity: capacity, charging: charging);

class _FakeBatteryNotificationSink implements BatteryNotificationSink {
  final List<BatteryNotification> notifications = <BatteryNotification>[];
  int dismissals = 0;

  @override
  Future<void> show(BatteryNotification notification) async {
    notifications.add(notification);
  }

  @override
  Future<void> dismiss() async {
    dismissals += 1;
  }

  @override
  Future<void> close() async {}
}
