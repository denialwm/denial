import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/state/network_connectivity.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/shade/system_shade_layer.dart';
import 'package:denial_dart_shell/src/widgets/shade/mobile_notification_history.dart';
import 'package:denial_dart_shell/src/widgets/shell_backdrop_blur.dart';
import 'package:denial_dart_shell/src/widgets/shade/quick_settings_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('closing a short or interrupted shade drag releases home input', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWith((_) => Stream.value(DateTime(2026, 9, 5))),
          networkConnectivityProvider.overrideWithBuild(
            (_, _) => NetworkConnectivityState.initial(),
          ),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(400, 800)),
              child: ShellTheme(
                data: const ShellThemeData(),
                child: Overlay.wrap(
                  child: DefaultTextStyle(
                    style: const TextStyle(fontSize: 14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => taps++,
                          child: const SizedBox.expand(),
                        ),
                        const SystemShadeLayer(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SystemShadeLayer)),
    );
    final shell = container.read(shellControllerProvider.notifier);
    await tester.tapAt(const Offset(200, 790));
    expect(taps, 1);
    taps = 0;
    for (final distance in [0.1, 1.0, 10.0, 100.0]) {
      shell.startQuickSettingsDrag();
      shell.updateQuickSettingsDrag(Offset(0, distance));
      await tester.pump();
      shell.endQuickSettingsDrag(0);
      await tester.pumpAndSettle(const Duration(milliseconds: 8));
      expect(
        container.read(shellControllerProvider).quickSettingsVisible,
        isFalse,
      );
      await tester.tapAt(const Offset(200, 790));
      expect(taps, 1, reason: 'Home blocked after $distance px drag');
      taps = 0;
    }
    shell.openQuickSettings();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final paintedProgress = tester
        .widget<QuickSettingsShade>(find.byType(QuickSettingsShade))
        .progress
        .value;
    shell.startQuickSettingsDrag(progress: paintedProgress);
    expect(
      container.read(shellControllerProvider).quickSettingsDragProgress,
      closeTo(paintedProgress, 0.000001),
    );
    shell.closeQuickSettings();
    await tester.pump(const Duration(milliseconds: 8));
    shell.openQuickSettings();
    await tester.pumpAndSettle(const Duration(milliseconds: 8));
    // Notifications float below the original 580px panel, with an independent
    // scroll view and no enclosing controls-panel backdrop.
    final history = find.byType(MobileNotificationHistory);
    expect(tester.getTopLeft(history).dy, closeTo(588, 0.01));
    expect(
      find.ancestor(of: history, matching: find.byType(ShellBackdropBlur)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(QuickSettingsShade),
        matching: find.byType(Scrollable),
      ),
      findsNWidgets(2),
    );
    // Reopening cancels the previous close, so the shade still owns this tap.
    await tester.tapAt(const Offset(200, 790));
    expect(taps, 0);
    expect(
      container.read(shellControllerProvider).quickSettingsVisible,
      isFalse,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 8));
    await tester.tapAt(const Offset(200, 790));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
