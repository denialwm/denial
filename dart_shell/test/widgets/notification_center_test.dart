import 'dart:async';

import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:denial_dart_shell/src/state/desktop_notifications.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/notification_center.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'center marks read and exposes DND, privacy, actions, dismissal, and clear-all',
      (tester) async {
    final events = StreamController<DesktopNotificationEvent>(sync: true);
    final dismissed = <int>[];
    final invoked = <(int, String)>[];
    final controller = DesktopNotificationsController(
      events.stream,
      dismiss: (id) {
        dismissed.add(id);
        return true;
      },
      invokeAction: (id, action) {
        invoked.add((id, action));
        return true;
      },
      invokeDefaultAction: (id) {
        invoked.add((id, 'default'));
        return true;
      },
    );
    events
      ..add(_event(1))
      ..add(_event(2));
    final container = ProviderContainer(
      overrides: <Override>[
        desktopNotificationsProvider.overrideWith((ref) => controller),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(340, 620),
              textScaler: TextScaler.linear(1.35),
            ),
            child: DefaultTextStyle(
              style: ShellText.base,
              child: const SizedBox(
                width: 340,
                height: 620,
                child: NotificationCenter(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.state.unreadCount, 0);
    expect(find.text('Summary 2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel('Enable do not disturb'));
    await tester.pump();
    expect(controller.state.doNotDisturb, isTrue);
    expect(find.textContaining('critical alerts can bypass'), findsOneWidget);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Full lock screen previews',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Full'));
    await tester.pump();
    expect(controller.state.lockPreview, NotificationPreviewMode.full);

    await tester.ensureVisible(find.text('Accept').first);
    await tester.tap(find.text('Accept').first);
    expect(invoked, <(int, String)>[(2, 'accept')]);

    await tester.ensureVisible(
      find.bySemanticsLabel('Dismiss notification').first,
    );
    await tester.tap(find.bySemanticsLabel('Dismiss notification').first);
    await tester.pump();
    expect(
      controller.state.history.map((record) => record.notification.id),
      <int>[1],
    );

    await tester.tap(find.bySemanticsLabel('Clear all notifications'));
    await tester.pump();
    expect(controller.state.history, isEmpty);
    expect(controller.state.pendingDismissals, <int>{1, 2});
    expect(dismissed, <int>[2, 1]);
  });
}

DesktopNotificationEvent _event(int id) {
  return DesktopNotificationEvent(
    kind: DesktopNotificationEventKind.added,
    notificationId: id,
    closeReason: 0,
    notification: DesktopNotification(
      id: id,
      sender: ':1.$id',
      appName: 'Test client',
      appIcon: '',
      summary: 'Summary $id',
      body: 'Body $id',
      actions: const <DesktopNotificationAction>[
        DesktopNotificationAction(key: 'default', label: 'Open'),
        DesktopNotificationAction(key: 'accept', label: 'Accept'),
      ],
      urgency: DesktopNotificationUrgency.normal,
      category: 'test',
      desktopEntry: '',
      imagePath: '',
      imageData: null,
      resident: false,
      transient: false,
      suppressSound: true,
      actionIcons: false,
      soundName: '',
      soundFile: '',
      x: 0,
      y: 0,
      hasPosition: false,
      progress: 0,
      hasProgress: false,
      expireTimeoutMs: -1,
    ),
  );
}
