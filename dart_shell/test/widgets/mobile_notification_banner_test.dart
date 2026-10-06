import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/notification_banner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/notification_fixture.dart';

void main() {
  testWidgets('heads-up travels from above screen without changing card size', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(notification: notificationFixture()));
    await tester.pump();
    final card = find.byType(NotificationCard);
    final size = tester.getSize(card);
    expect(tester.getBottomLeft(card).dy, lessThanOrEqualTo(0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(card), size);
    final midway = tester.getTopLeft(card).dy;
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(card).dy, greaterThan(midway));
    expect(tester.getTopLeft(card).dy, 80); // 24 safe + 48 status + 8 gutter.
    expect(tester.getSize(card).width, 368);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('timeout and upward swipe hide without dismissing', (
    tester,
  ) async {
    final hidden = <int>[];
    final dismissed = <int>[];
    await tester.pumpWidget(
      _harness(
        notification: notificationFixture(),
        onHide: hidden.add,
        onDismiss: (id) {
          dismissed.add(id);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(NotificationCard), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(hidden, [1]);
    expect(dismissed, isEmpty);
    await tester.pumpWidget(
      _harness(notification: notificationFixture(id: 2), onHide: hidden.add),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(hidden, [1, 2]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wide heads-up keeps history width and expands actions on tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(notification: notificationFixture(), width: 610),
    );
    await tester.pumpAndSettle();
    final card = find.byType(NotificationCard);
    expect(tester.getSize(card).width, 578);
    expect(find.text('Reply'), findsNothing);
    await tester.tap(card);
    await tester.pump();
    expect(find.text('Reply'), findsOneWidget);
    await tester.tap(find.text('Message body'));
    await tester.pump();
    expect(find.text('Reply'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'replacement stays in one slot and locked preview hides content',
    (tester) async {
      await tester.pumpWidget(_harness(notification: notificationFixture()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _harness(
          notification: notificationFixture(summary: 'Updated secret'),
          preview: NotificationPreviewMode.applicationOnly,
          interactive: false,
        ),
      );
      expect(find.byType(NotificationCard), findsOneWidget);
      expect(find.text('Updated secret'), findsNothing);
      expect(find.text('Message body'), findsNothing);
      expect(find.text('Reply'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced motion settles immediately and persistent input is absent',
    (tester) async {
      await tester.pumpWidget(
        _harness(notification: notificationFixture(), reducedMotion: true),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(NotificationCard)).dy, 80);
      await tester.pumpWidget(
        _harness(
          notification: notificationFixture(resident: true),
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NotificationCard), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Widget _harness({
  required DesktopNotification? notification,
  ValueChanged<int>? onHide,
  bool Function(int)? onDismiss,
  bool reducedMotion = false,
  bool interactive = true,
  double width = 400,
  NotificationPreviewMode preview = NotificationPreviewMode.full,
}) => ProviderScope(
  child: DenialLocalizationScope(
    locale: const Locale('en'),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          viewPadding: const EdgeInsets.only(top: 24),
          disableAnimations: reducedMotion,
        ),
        child: ShellTheme(
          data: const ShellThemeData(),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 800,
              child: MobileNotificationBannerView(
                notification: notification,
                onHide: onHide ?? (_) {},
                onDismiss: onDismiss,
                onAction: (_, _) => true,
                previewMode: preview,
                interactive: interactive,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
