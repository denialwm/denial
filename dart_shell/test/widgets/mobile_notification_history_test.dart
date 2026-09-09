import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/widgets/notification_banner.dart';
import 'package:denial_dart_shell/src/widgets/notification_media.dart';
import 'package:denial_dart_shell/src/widgets/shade/mobile_notification_history.dart';
import 'package:denial_dart_shell/src/widgets/shade/notification_shade_list.dart';
import 'package:denial_dart_shell/src/widgets/shade/quick_settings_panel.dart';
import 'package:denial_dart_shell/src/widgets/shade/range_bar.dart';
import 'package:denial_dart_shell/src/widgets/shell_backdrop_blur.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/desktop_notifications_harness.dart';
import '../support/notification_fixture.dart';

void main() {
  for (final count in [0, 1, 12]) {
    testWidgets('vertical history gestures with $count notifications', (
      tester,
    ) async {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      for (var id = 1; id <= count; id++) {
        harness.add(
          notificationEvent(notificationFixture(id: id, resident: true)),
        );
      }
      final shell = harness.container.read(shellControllerProvider.notifier);
      shell.openQuickSettings();
      await tester.pumpWidget(
        _harness(
          harness,
          const MobileNotificationHistory(
            progress: AlwaysStoppedAnimation(1),
            closed: false,
          ),
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.maxScrollExtent > 0, count == 12);
      final start = count == 0
          ? const Offset(200, 250)
          : tester.getCenter(find.byType(NotificationCard).first);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(0, -25));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, -70));
      await tester.pump(const Duration(milliseconds: 200));
      final during = harness.container.read(shellControllerProvider);
      expect(during.quickSettingsDragActive, count != 12);
      if (count == 12) {
        expect(position.pixels, greaterThan(0));
      } else {
        expect(during.quickSettingsDragProgress, lessThan(1));
        expect(during.quickSettingsDragProgress, greaterThan(0));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        harness.container.read(shellControllerProvider).quickSettingsVisible,
        count == 12,
      );
      expect(harness.state.history, hasLength(count));
      if (count == 12) {
        // A flick at either scroll boundary must still leave the panel open.
        for (final edge in [
          position.minScrollExtent,
          position.maxScrollExtent,
        ]) {
          position.jumpTo(edge);
          await tester.pump();
          await tester.fling(
            find.byType(CustomScrollView),
            const Offset(0, -100),
            1500,
          );
          await tester.pumpAndSettle();
          expect(
            harness.container
                .read(shellControllerProvider)
                .quickSettingsVisible,
            isTrue,
          );
          expect(
            harness.container
                .read(shellControllerProvider)
                .quickSettingsDragActive,
            isFalse,
          );
        }
      } else {
        shell.openQuickSettings();
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, -70),
          1500,
        );
        await tester.pumpAndSettle();
        expect(
          harness.container.read(shellControllerProvider).quickSettingsVisible,
          isFalse,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('only a completed closed state rearms the entrance', (
    tester,
  ) async {
    final harness = DesktopNotificationsTestHarness();
    addTearDown(harness.dispose);
    harness.add(notificationEvent(notificationFixture(resident: true)));
    final progress = AnimationController(vsync: tester);
    addTearDown(progress.dispose);
    Widget view(bool closed) => _harness(
      harness,
      MobileNotificationHistory(progress: progress, closed: closed),
    );
    await tester.pumpWidget(view(true));
    Animation<double> entrance() => tester
        .widget<NotificationShadeList>(find.byType(NotificationShadeList))
        .entrance;
    progress.value = 0.4;
    await tester.pumpWidget(view(false));
    await tester.pump(const Duration(milliseconds: 150));
    final started = entrance().value;
    expect(started, greaterThan(0));
    progress.value = 0.1;
    await tester.pump(const Duration(milliseconds: 80));
    expect(entrance().value, greaterThan(started));
    // Touching zero while still holding the handle is not the closed state.
    progress.value = 0;
    await tester.pump(const Duration(milliseconds: 40));
    final beforeReversal = entrance().value;
    progress.value = 0.5;
    await tester.pump();
    expect(entrance().value, greaterThanOrEqualTo(beforeReversal));
    progress.value = 1;
    await tester.pumpAndSettle();
    expect(entrance().value, 1);
    progress.value = 0;
    await tester.pumpWidget(view(true));
    progress.value = 0.2;
    await tester.pumpWidget(view(false));
    expect(entrance().value, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'history exposes persistent entries, expansion, actions and swipe dismissal',
    (tester) async {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      harness.add(notificationEvent(notificationFixture(resident: true)));
      final progress = AnimationController(vsync: tester, value: 1);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        _harness(
          harness,
          MobileNotificationHistory(progress: progress, closed: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Message title'), findsOneWidget);
      expect(harness.state.bannerQueue, isEmpty);
      expect(find.text('Reply'), findsNothing);
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsOneWidget);
      await tester.tap(find.text('Reply'));
      expect(harness.invoked, [(1, 'reply')]);
      await tester.drag(find.byType(NotificationCard), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(harness.dismissed, [1]);
      expect(harness.state.history, isEmpty);
      expect(find.text('No notifications'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('history glass shares one backdrop captured before the cards', (
    tester,
  ) async {
    final harness = DesktopNotificationsTestHarness();
    addTearDown(harness.dispose);
    harness.add(notificationEvent(notificationFixture(id: 1, resident: true)));
    harness.add(notificationEvent(notificationFixture(id: 2, resident: true)));
    await tester.pumpWidget(
      _harness(
        harness,
        const MobileNotificationHistory(
          progress: AlwaysStoppedAnimation(0.5),
          closed: false,
        ),
        reducedMotion: true,
      ),
    );
    final filters = tester
        .renderObjectList<RenderBackdropFilter>(find.byType(BackdropFilter))
        .toList();
    expect(filters, hasLength(2));
    expect(filters.first.backdropKey, isNotNull);
    expect(filters.last.backdropKey, same(filters.first.backdropKey));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cards use theme roundness and readable mobile type', (
    tester,
  ) async {
    final harness = DesktopNotificationsTestHarness();
    addTearDown(harness.dispose);
    harness.add(notificationEvent(notificationFixture(resident: true)));
    const theme = ShellThemeData(cornerRadiusScale: 1.4);
    await tester.pumpWidget(
      _harness(
        harness,
        const MobileNotificationHistory(
          progress: AlwaysStoppedAnimation(1),
          closed: false,
        ),
        reducedMotion: true,
        theme: theme,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ShellBackdropBlur>(find.byType(ShellBackdropBlur))
          .borderRadius,
      BorderRadius.circular(theme.panelRadius),
    );
    expect(
      tester
          .widget<NotificationShadeSurface>(
            find.byType(NotificationShadeSurface),
          )
          .borderRadius,
      BorderRadius.circular(theme.panelRadius),
    );
    expect(tester.widget<Text>(find.text('Message title')).style!.fontSize, 20);
    expect(tester.widget<Text>(find.text('Message body')).style!.fontSize, 18);
    expect(
      tester.getSize(find.byType(NotificationCard)).height,
      greaterThanOrEqualTo(96),
    );
    final artwork = find.byType(NotificationArtwork);
    expect(tester.getSize(artwork), const Size(56, 56));
    final title = find.text('Message title');
    final body = find.text('Message body');
    expect(tester.getTopLeft(title).dx, tester.getTopLeft(body).dx);
    expect(
      tester.getTopLeft(title).dx,
      greaterThan(tester.getTopRight(artwork).dx),
    );
    expect(tester.widget<Text>(title).style!.color, theme.colors.textPrimary);
    expect(tester.widget<Text>(body).style!.color, theme.colors.textPrimary);
    expect(tester.widget<Text>(title).style!.fontWeight, FontWeight.w700);
    expect(tester.widget<Text>(body).style!.fontWeight, FontWeight.w400);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'clear all lives below volume in the controls and clears history',
    (tester) async {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      harness.add(notificationEvent(notificationFixture(resident: true)));
      await tester.pumpWidget(
        _harness(
          harness,
          const QuickSettingsShade(progress: AlwaysStoppedAnimation(1)),
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      final clear = find.byType(ClearNotificationHistoryButton);
      expect(
        find.descendant(
          of: find.byType(MobileNotificationHistory),
          matching: clear,
        ),
        findsNothing,
      );
      await tester.ensureVisible(clear);
      expect(
        tester.getTopLeft(clear).dy,
        greaterThanOrEqualTo(
          tester.getBottomLeft(find.byType(RangeBar).last).dy,
        ),
      );
      expect(tester.getTopRight(clear).dx, closeTo(384, 0.1));
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(harness.state.history, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty history space dismisses while card controls do not', (
    tester,
  ) async {
    final harness = DesktopNotificationsTestHarness();
    addTearDown(harness.dispose);
    harness.add(notificationEvent(notificationFixture(resident: true)));
    final shell = harness.container.read(shellControllerProvider.notifier);
    shell.openQuickSettings();
    await tester.pumpWidget(
      _harness(
        harness,
        const MobileNotificationHistory(
          progress: AlwaysStoppedAnimation(1),
          closed: false,
        ),
        reducedMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsNothing);
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .clipBehavior,
      Clip.none,
    );
    expect(tester.getSize(find.byType(CustomScrollView)).width, 400);
    expect(tester.getTopLeft(find.byType(NotificationCard)).dx, 16);
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();
    expect(
      harness.container.read(shellControllerProvider).quickSettingsVisible,
      isTrue,
    );
    await tester.tapAt(const Offset(200, 500));
    expect(
      harness.container.read(shellControllerProvider).quickSettingsVisible,
      isFalse,
    );
    shell.openQuickSettings();
    final cardBottom = tester.getBottomLeft(find.byType(NotificationCard));
    await tester.tapAt(cardBottom + const Offset(20, 5));
    expect(
      harness.container.read(shellControllerProvider).quickSettingsVisible,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reduced motion skips stagger while panel progress still tracks drag',
    (tester) async {
      final harness = DesktopNotificationsTestHarness();
      addTearDown(harness.dispose);
      harness.add(notificationEvent(notificationFixture(resident: true)));
      final progress = AnimationController(vsync: tester, value: 0.5);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        _harness(
          harness,
          MobileNotificationHistory(progress: progress, closed: false),
          reducedMotion: true,
        ),
      );
      final list = tester.widget<NotificationShadeList>(
        find.byType(NotificationShadeList),
      );
      expect(list.entrance.value, 1);
      expect(list.progress.value, 0.5);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Widget _harness(
  DesktopNotificationsTestHarness harness,
  Widget child, {
  bool reducedMotion = false,
  ShellThemeData theme = const ShellThemeData(),
}) => UncontrolledProviderScope(
  container: harness.container,
  child: DenialLocalizationScope(
    locale: const Locale('en'),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          disableAnimations: reducedMotion,
        ),
        child: ShellTheme(
          data: theme,
          child: BackdropGroup(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 800,
                child: Overlay.wrap(
                  child: DefaultTextStyle(
                    style: const TextStyle(fontSize: 14),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
