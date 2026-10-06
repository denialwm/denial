import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_layout_page.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scrolling layout exposes wheel speed and direction controls', (
    tester,
  ) async {
    double? speed;
    ScrollingLayoutWheelUpDirection? direction;
    await tester.pumpWidget(
      _harness(
        const ShellLayoutSettings(
          windowLayout: DesktopWindowLayout.scrolling,
          scrollingLayoutWheelSpeed: 1.75,
          scrollingLayoutWheelUpDirection:
              ScrollingLayoutWheelUpDirection.right,
        ),
        onSpeedChanged: (value) => speed = value,
        onDirectionChanged: (value) => direction = value,
      ),
    );

    final slider = tester.widget<SettingsSlider>(
      find.byKey(settingsScrollingLayoutWheelSpeedSliderKey),
    );
    expect(slider.label, 'Wheel speed');
    expect(slider.value, 1.75);
    expect(slider.minimum, scrollingLayoutWheelSpeedMinimum);
    expect(slider.maximum, scrollingLayoutWheelSpeedMaximum);
    slider.onChanged(2.25);

    final directionControl = tester
        .widget<SettingsSegmentedControl<ScrollingLayoutWheelUpDirection>>(
          find.byType(
            SettingsSegmentedControl<ScrollingLayoutWheelUpDirection>,
          ),
        );
    directionControl.onChanged(ScrollingLayoutWheelUpDirection.left);

    expect(speed, 2.25);
    expect(direction, ScrollingLayoutWheelUpDirection.left);
  });

  testWidgets('non-scrolling layouts hide wheel controls', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ShellLayoutSettings(),
        onSpeedChanged: (_) {},
        onDirectionChanged: (_) {},
      ),
    );

    expect(
      find.byKey(settingsScrollingLayoutWheelSpeedSliderKey),
      findsNothing,
    );
    expect(find.text('Super + mouse wheel'), findsNothing);
  });
}

Widget _harness(
  ShellLayoutSettings settings, {
  required ValueChanged<double> onSpeedChanged,
  required ValueChanged<ScrollingLayoutWheelUpDirection> onDirectionChanged,
}) {
  return MaterialApp(
    home: DenialLocalizationScope(
      locale: const Locale('en'),
      child: ShellTheme(
        data: const ShellThemeData(),
        child: Material(
          child: SettingsLayoutPage(
            settings: settings,
            displayLayout: null,
            onWindowLayoutChanged: (_) {},
            onScrollingLayoutWheelSpeedChanged: onSpeedChanged,
            onScrollingLayoutWheelUpDirectionChanged: onDirectionChanged,
            onWorkspacesEnabledChanged: (_) {},
            onWorkspaceCountChanged: (_) {},
            onWorkspaceSwitchingOrientationChanged: (_) {},
            onSystemBarChanged: (_, _) {},
            onSystemBarThicknessChanged: (_) {},
            onMaximizePaddingChanged: (_) {},
            onMinimizedWindowPlacementChanged: (_) {},
            onClipboardTrayEdgeChanged: (_) {},
            onClipboardTrayExtentChanged: (_) {},
            onReset: () {},
          ),
        ),
      ),
    ),
  );
}
