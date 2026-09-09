import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/desktop_notifications_harness.dart';
import '../support/notification_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final notification in [
    notificationFixture(resident: true),
    notificationFixture(timeout: 0),
    notificationFixture(resident: true, transient: true),
    notificationFixture(
      timeout: 0,
      urgency: DesktopNotificationUrgency.critical,
    ),
  ]) {
    test(
      'persistent notification ${notification.resident}/${notification.transient}/${notification.expireTimeoutMs}/${notification.urgency} stays only in history',
      () async {
        final harness = DesktopNotificationsTestHarness();
        addTearDown(harness.dispose);
        harness.add(notificationEvent(notification));
        expect(harness.state.bannerQueue, isEmpty);
        expect(harness.state.bannerNotifications, isEmpty);
        expect(harness.state.history.single.notification, notification);
        expect(harness.state.active[notification.id], notification);
        expect(harness.dismissed, isEmpty);
        harness.controller.setDoNotDisturb(true);
        harness.controller.setDoNotDisturb(false);
        expect(harness.state.bannerNotifications, isEmpty);
      },
    );
  }

  test(
    'replacement becoming persistent removes banner and updates history',
    () {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      harness.add(notificationEvent(notificationFixture()));
      expect(harness.state.bannerNotifications, hasLength(1));
      harness.add(
        notificationEvent(
          notificationFixture(resident: true, summary: 'Still running'),
          kind: DesktopNotificationEventKind.replaced,
        ),
      );
      expect(harness.state.bannerQueue, isEmpty);
      expect(
        harness.state.history.single.notification.summary,
        'Still running',
      );
      expect(harness.state.history.single.active, isTrue);
    },
  );

  test('hiding heads-up preserves unread history and active actions', () {
    final harness = DesktopNotificationsTestHarness();
    addTearDown(harness.dispose);
    harness.add(notificationEvent(notificationFixture()));
    harness.controller.hideBanner(1);
    expect(harness.state.bannerNotifications, isEmpty);
    expect(harness.state.history.single.unread, isTrue);
    expect(harness.state.active, contains(1));
    expect(harness.dismissed, isEmpty);
    expect(harness.controller.invokeAction(1, 'reply'), isTrue);
    expect(harness.invoked, [(1, 'reply')]);
  });

  test(
    'ordinary transient notifications still use banners without history',
    () {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      harness.add(notificationEvent(notificationFixture(transient: true)));
      expect(harness.state.bannerNotifications, hasLength(1));
      expect(harness.state.history, isEmpty);
    },
  );
}
