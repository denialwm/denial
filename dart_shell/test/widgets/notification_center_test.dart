import 'dart:ui' show SemanticsRole;

import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/notification_center.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/desktop_notifications_harness.dart';

void main() {
  testWidgets(
    'center marks read and exposes DND, privacy, actions, dismissal, and clear-all',
    (tester) async {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      harness
        ..add(_event(1))
        ..add(_event(2));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: DenialLocalizationScope(
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

      expect(harness.state.unreadCount, 0);
      expect(find.text('Summary 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final semanticRoles = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((widget) => widget.properties.role)
          .toList(growable: false);
      expect(semanticRoles, containsAll(<SemanticsRole>[.list, .radioGroup]));

      await tester.tap(find.bySemanticsLabel('Enable do not disturb'));
      await tester.pump();
      expect(harness.state.doNotDisturb, isTrue);
      expect(find.textContaining('critical alerts can bypass'), findsOneWidget);

      final fullPreviewSemantics = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Full lock screen previews',
        ),
      );
      expect(fullPreviewSemantics.properties.inMutuallyExclusiveGroup, isTrue);
      await tester.tap(find.text('Full'));
      await tester.pump();
      expect(harness.state.lockPreview, NotificationPreviewMode.full);

      await tester.ensureVisible(find.text('Accept').first);
      await tester.tap(find.text('Accept').first);
      expect(harness.invoked, <(int, String)>[(2, 'accept')]);

      await tester.ensureVisible(
        find.bySemanticsLabel('Dismiss notification').first,
      );
      await tester.tap(find.bySemanticsLabel('Dismiss notification').first);
      await tester.pump();
      expect(
        harness.state.history.map((record) => record.notification.id),
        <int>[1],
      );

      await tester.tap(find.bySemanticsLabel('Clear all notifications'));
      await tester.pump();
      expect(harness.state.history, isEmpty);
      expect(harness.state.pendingDismissals, <int>{1, 2});
      expect(harness.dismissed, <int>[2, 1]);
    },
  );
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
