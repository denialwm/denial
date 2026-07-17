import 'dart:async';

import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:denial_dart_shell/src/state/desktop_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retains lifecycle, replaces in place, and guards actions', () async {
    final harness = _NotificationHarness();
    addTearDown(harness.dispose);

    harness.add(_event(9, DesktopNotificationEventKind.added));

    expect(harness.controller.state.active.keys, <int>[9]);
    expect(harness.controller.state.history, hasLength(1));
    expect(harness.controller.state.bannerNotification!.id, 9);
    expect(harness.logs.single, contains('Denial notification added'));
    expect(harness.controller.dismiss(9), isTrue);
    expect(harness.controller.dismiss(9), isFalse);
    expect(harness.controller.invokeAction(9, 'accept'), isTrue);
    expect(harness.controller.invokeAction(9, 'accept'), isFalse);
    expect(harness.controller.invokeAction(9, 'missing'), isFalse);
    expect(harness.controller.invokeDefaultAction(9), isTrue);
    expect(harness.controller.invokeDefaultAction(9), isFalse);
    expect(harness.dismissed, <int>[9]);
    expect(harness.invoked, <(int, String)>[(9, 'accept')]);
    expect(harness.defaultInvoked, <int>[9]);

    harness.add(_event(10, DesktopNotificationEventKind.added));
    expect(
      harness.controller.state.bannerNotifications.map((item) => item.id),
      <int>[10],
      reason: 'a pending dismissal is hidden before its native close event',
    );

    harness.add(
      _event(
        9,
        DesktopNotificationEventKind.replaced,
        summary: 'Replacement',
      ),
    );
    expect(harness.controller.state.history, hasLength(2));
    expect(
      harness.controller.state.history
          .singleWhere((record) => record.notification.id == 9)
          .notification
          .summary,
      'Replacement',
    );
    expect(
      harness.controller.state.bannerNotifications.map((item) => item.id),
      <int>[9, 10],
    );

    harness.add(const DesktopNotificationEvent(
      kind: DesktopNotificationEventKind.closed,
      notificationId: 9,
      closeReason: 3,
    ));

    expect(harness.controller.state.active.keys, <int>[10]);
    final closed = harness.controller.state.history
        .singleWhere((record) => record.notification.id == 9);
    expect(closed.active, isFalse);
    expect(closed.closeReason, 3);
    expect(harness.logs.last, contains('closed by sender'));
  });

  test('burst, visible cards, queue, active state, and history stay bounded',
      () async {
    final harness = _NotificationHarness();
    addTearDown(harness.dispose);

    for (var id = 1; id <= 280; id += 1) {
      harness.add(_event(id, DesktopNotificationEventKind.added));
    }

    expect(
      harness.controller.state.active,
      hasLength(DesktopNotificationsController.maxActiveNotifications),
    );
    expect(
      harness.controller.state.history,
      hasLength(DesktopNotificationsController.maxHistoryEntries),
    );
    expect(
      harness.controller.state.bannerQueue,
      hasLength(DesktopNotificationsController.maxBannerQueue),
    );
    expect(
      harness.controller.state.bannerNotifications.map((item) => item.id),
      <int>[280, 279, 278],
    );

    harness.add(
      _event(
        280,
        DesktopNotificationEventKind.replaced,
        summary: 'Updated',
      ),
    );
    expect(
      harness.controller.state.history
          .where((record) => record.notification.id == 280),
      hasLength(1),
    );
  });

  test(
      'DND suppresses ordinary banners, retains history, and lets critical bypass',
      () async {
    final harness = _NotificationHarness();
    addTearDown(harness.dispose);

    harness.add(_event(1, DesktopNotificationEventKind.added));
    harness.add(_event(
      2,
      DesktopNotificationEventKind.added,
      urgency: DesktopNotificationUrgency.critical,
    ));
    harness.controller.setDoNotDisturb(true);
    expect(
      harness.controller.state.bannerNotifications.map((item) => item.id),
      <int>[2],
    );

    harness.add(_event(3, DesktopNotificationEventKind.added));
    harness.add(_event(
      4,
      DesktopNotificationEventKind.added,
      urgency: DesktopNotificationUrgency.critical,
    ));
    expect(harness.controller.state.history, hasLength(4));
    expect(
      harness.controller.state.bannerNotifications.map((item) => item.id),
      <int>[4, 2],
    );

    harness.controller.setDoNotDisturb(false);
    harness.add(_event(5, DesktopNotificationEventKind.added));
    expect(
      harness.controller.state.bannerNotifications.map((item) => item.id),
      <int>[5, 4, 2],
      reason: 'turning DND off does not replay stale ordinary banners',
    );
  });

  test(
      'transient notifications skip history and clear-all dismisses active items',
      () async {
    final harness = _NotificationHarness();
    addTearDown(harness.dispose);

    harness.add(_event(1, DesktopNotificationEventKind.added, transient: true));
    harness.add(_event(2, DesktopNotificationEventKind.added));
    expect(harness.controller.state.active, hasLength(2));
    expect(
      harness.controller.state.history.map((record) => record.notification.id),
      <int>[2],
    );

    harness.controller.clearAll();
    expect(harness.dismissed, <int>[1, 2]);
    expect(harness.controller.state.history, isEmpty);
    expect(harness.controller.state.bannerNotifications, isEmpty);
    expect(harness.controller.state.pendingDismissals, <int>{1, 2});
  });

  test('read state and privacy policy are explicit', () async {
    final harness = _NotificationHarness();
    addTearDown(harness.dispose);

    harness.add(_event(1, DesktopNotificationEventKind.added));
    harness.add(_event(2, DesktopNotificationEventKind.added));
    expect(harness.controller.state.unreadCount, 2);
    harness.controller.markAllRead();
    expect(harness.controller.state.unreadCount, 0);
    harness.controller.setLockPreview(NotificationPreviewMode.hidden);
    expect(
      harness.controller.state.lockPreview,
      NotificationPreviewMode.hidden,
    );
  });

  test('loads and serializes persistent policy without storing notifications',
      () async {
    final events = StreamController<DesktopNotificationEvent>(sync: true);
    final store = _FakePolicyStore(
      const NotificationPolicy(
        doNotDisturb: true,
        lockPreview: NotificationPreviewMode.full,
      ),
    );
    final controller = DesktopNotificationsController(
      events.stream,
      dismiss: (_) => true,
      invokeAction: (_, __) => true,
      invokeDefaultAction: (_) => true,
      policyStore: store,
    );
    addTearDown(() async {
      controller.dispose();
      await events.close();
    });

    expect(controller.state.policyLoaded, isFalse);
    await _settleAsync();
    expect(controller.state.policyLoaded, isTrue);
    expect(controller.state.doNotDisturb, isTrue);
    expect(controller.state.lockPreview, NotificationPreviewMode.full);

    controller.setDoNotDisturb(false);
    controller.setLockPreview(NotificationPreviewMode.applicationOnly);
    await _settleAsync();
    expect(store.writes.last.doNotDisturb, isFalse);
    expect(
      store.writes.last.lockPreview,
      NotificationPreviewMode.applicationOnly,
    );
  });
}

class _NotificationHarness {
  _NotificationHarness() {
    controller = DesktopNotificationsController(
      events.stream,
      dismiss: (notificationId) {
        dismissed.add(notificationId);
        return true;
      },
      invokeAction: (notificationId, actionKey) {
        invoked.add((notificationId, actionKey));
        return true;
      },
      invokeDefaultAction: (notificationId) {
        defaultInvoked.add(notificationId);
        return true;
      },
      logger: logs.add,
    );
  }

  final StreamController<DesktopNotificationEvent> events =
      StreamController<DesktopNotificationEvent>(sync: true);
  final List<String> logs = <String>[];
  final List<int> dismissed = <int>[];
  final List<(int, String)> invoked = <(int, String)>[];
  final List<int> defaultInvoked = <int>[];
  late final DesktopNotificationsController controller;

  void add(DesktopNotificationEvent event) => events.add(event);

  Future<void> dispose() async {
    controller.dispose();
    await events.close();
  }
}

class _FakePolicyStore implements NotificationPolicyStore {
  _FakePolicyStore(this.value);

  final NotificationPolicy value;
  final List<NotificationPolicy> writes = <NotificationPolicy>[];

  @override
  Future<NotificationPolicy> read() async => value;

  @override
  Future<void> write(NotificationPolicy policy) async {
    writes.add(policy);
  }
}

Future<void> _settleAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

DesktopNotificationEvent _event(
  int id,
  DesktopNotificationEventKind kind, {
  String summary = 'Test summary',
  DesktopNotificationUrgency urgency = DesktopNotificationUrgency.normal,
  bool transient = false,
}) {
  return DesktopNotificationEvent(
    kind: kind,
    notificationId: id,
    closeReason: 0,
    notification: _notification(
      id,
      summary: summary,
      urgency: urgency,
      transient: transient,
    ),
  );
}

DesktopNotification _notification(
  int id, {
  required String summary,
  required DesktopNotificationUrgency urgency,
  required bool transient,
}) {
  return DesktopNotification(
    id: id,
    sender: ':1.7',
    appName: 'Test client',
    appIcon: '',
    summary: summary,
    body: 'Test body',
    actions: const <DesktopNotificationAction>[
      DesktopNotificationAction(key: 'default', label: 'Open'),
      DesktopNotificationAction(key: 'accept', label: 'Accept'),
    ],
    urgency: urgency,
    category: 'test',
    desktopEntry: '',
    imagePath: '',
    imageData: null,
    resident: false,
    transient: transient,
    suppressSound: false,
    actionIcons: false,
    soundName: '',
    soundFile: '',
    x: 0,
    y: 0,
    hasPosition: false,
    progress: 0,
    hasProgress: false,
    expireTimeoutMs: -1,
  );
}
