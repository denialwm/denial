import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/notification_banner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/notification_fixture.dart';

void main() {
  testWidgets('desktop banner owns native input through its visible exit', (
    tester,
  ) async {
    final notification = notificationFixture();
    await tester.pumpWidget(_harness([notification]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotificationBannerView)),
    );
    final settledRegions = container
        .read(shellInteractionRegistryProvider)
        .childRegions;
    expect(settledRegions, hasLength(1));
    expect(
      settledRegions.single.contains(
        tester.getCenter(find.byType(NotificationCard)),
      ),
      isTrue,
    );

    await tester.pumpWidget(_harness(const []));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NotificationCard), findsOneWidget);
    expect(
      container.read(shellInteractionRegistryProvider).childRegions,
      isNotEmpty,
    );

    await tester.pumpAndSettle();
    expect(find.byType(NotificationCard), findsNothing);
    expect(
      container.read(shellInteractionRegistryProvider).childRegions,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _harness(List<DesktopNotification> notifications) => ProviderScope(
  child: DenialLocalizationScope(
    locale: const Locale('en'),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(500, 800)),
        child: ShellTheme(
          data: const ShellThemeData(),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 410,
              height: 640,
              child: NotificationBannerView(
                notifications: notifications,
                onDismiss: (_) => true,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
