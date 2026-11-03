import 'package:denial_flutter_sdk/src/state/desktop_notification_reducer.dart'
    show DesktopNotificationReducer;

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/notification_event_fixtures.dart';

void main() {
  // History must hold exactly what deniald still holds: a card for a closed
  // notification would offer actions nobody can answer.
  test('history follows the notifications deniald holds', () {
    final reducer = DesktopNotificationReducer();
    var state = const DesktopNotificationsState();
    DesktopNotificationsState apply(DesktopNotificationEvent event) =>
        state = reducer.apply(state, event).state;
    List<int> history() => [
      for (final record in state.history) record.notification.id,
    ];

    apply(notificationEvent(1));
    apply(notificationEvent(2));
    expect(history(), [2, 1]);

    apply(
      notificationEvent(
        1,
        progress: 50,
        kind: DesktopNotificationEventKind.replaced,
      ),
    );
    expect(history(), [2, 1]);
    expect(state.history.last.notification.progress, 50);

    for (final reason in [1, 2, 3, 4]) {
      apply(notificationEvent(10 + reason));
      apply(closeNotification(10 + reason, reason: reason));
      expect(history(), [2, 1]);
    }

    apply(closeNotification(2));
    expect(history(), [1]);
    expect(state.active.keys, [1]);
  });

  test('evicting the oldest notification drops its card', () {
    final reducer = DesktopNotificationReducer();
    var state = const DesktopNotificationsState();
    for (
      var id = 1;
      id <= DesktopNotificationReducer.maxActiveNotifications;
      id++
    ) {
      state = reducer.apply(state, notificationEvent(id)).state;
    }
    final result = reducer.apply(state, notificationEvent(1000));
    expect(result.evictedId, 1);
    expect(
      result.state.history.map((record) => record.notification.id),
      isNot(contains(1)),
    );
    expect(
      result.state.history.length,
      DesktopNotificationReducer.maxActiveNotifications,
    );
  });

  test('quiet updates neither raise a banner nor mark the card unread', () {
    final reducer = DesktopNotificationReducer();
    var state = const DesktopNotificationsState();
    DesktopNotificationsState apply(DesktopNotificationEvent event) =>
        state = reducer.apply(state, event).state;

    apply(notificationEvent(1));
    apply(notificationEvent(2));
    expect(state.bannerQueue, [2, 1]);

    apply(
      notificationEvent(
        1,
        progress: 60,
        alert: false,
        kind: DesktopNotificationEventKind.replaced,
      ),
    );
    expect(state.bannerQueue, [2, 1]);
    expect(state.active[1]!.progress, 60);

    apply(notificationEvent(3, alert: false));
    expect(state.bannerQueue, [2, 1]);
    expect(state.history.first.notification.id, 3);
  });

  test('an alert takes over its group banner', () {
    final reducer = DesktopNotificationReducer();
    var state = const DesktopNotificationsState();
    DesktopNotificationsState apply(DesktopNotificationEvent event) =>
        state = reducer.apply(state, event).state;

    apply(notificationEvent(1, groupKey: 'mail'));
    apply(notificationEvent(2, groupKey: 'chat'));
    apply(notificationEvent(3, groupKey: 'mail'));
    expect(state.bannerQueue, [3, 2]);

    // A quiet post leaves the group's banner alone.
    apply(notificationEvent(4, groupKey: 'chat', alert: false));
    expect(state.bannerQueue, [3, 2]);

    // Notifications without a key never share a banner.
    apply(notificationEvent(5));
    apply(notificationEvent(6));
    expect(state.bannerQueue, [6, 5, 3, 2]);
  });

  test('groups stack from two members, newest first', () {
    final reducer = DesktopNotificationReducer();
    var state = const DesktopNotificationsState();
    DesktopNotificationsState apply(DesktopNotificationEvent event) =>
        state = reducer.apply(state, event).state;
    List<List<int>> groups() => [
      for (final group in state.groups)
        [for (final record in group.members) record.notification.id],
    ];

    apply(notificationEvent(1, groupKey: 'mail'));
    apply(notificationEvent(2, groupKey: 'chat', groupSummary: true));
    apply(notificationEvent(3));
    expect(groups(), [
      [3],
      [2],
      [1],
    ]);
    expect(state.groups.map((group) => group.stacked), [false, false, false]);

    // Once the group has members, its summary stands aside.
    apply(notificationEvent(4, groupKey: 'chat'));
    apply(notificationEvent(5, groupKey: 'mail'));
    expect(groups(), [
      [5, 1],
      [4],
      [3],
    ]);
    expect(state.groups[0].stacked, isTrue);
    expect(state.groups[1].summary?.notification.id, 2);
    expect(state.groups[1].records.map((record) => record.notification.id), [
      4,
      2,
    ]);
    expect(identical(state.groups, state.groups), isTrue);
  });
}
