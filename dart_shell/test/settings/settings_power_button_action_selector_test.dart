import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/power_button_action.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_power_button_action_selector.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('omits hibernate when logind reports it unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(value: PowerButtonAction.dpms, hibernateAvailable: false),
    );

    final select = tester.widget<DropdownButton<PowerButtonAction>>(
      find.byType(DropdownButton<PowerButtonAction>),
    );
    expect(select.items!.map((item) => item.value), <PowerButtonAction>[
      PowerButtonAction.suspend,
      PowerButtonAction.dpms,
      PowerButtonAction.powerOff,
    ]);
  });

  testWidgets('offers hibernate when logind reports it available', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(value: PowerButtonAction.dpms, hibernateAvailable: true),
    );

    final select = tester.widget<DropdownButton<PowerButtonAction>>(
      find.byType(DropdownButton<PowerButtonAction>),
    );
    expect(
      select.items!.map((item) => item.value),
      contains(PowerButtonAction.hibernate),
    );
  });

  testWidgets('keeps a persisted unavailable hibernate choice visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(value: PowerButtonAction.hibernate, hibernateAvailable: false),
    );

    final select = tester.widget<DropdownButton<PowerButtonAction>>(
      find.byType(DropdownButton<PowerButtonAction>),
    );
    final hibernate = select.items!.singleWhere(
      (item) => item.value == PowerButtonAction.hibernate,
    );
    expect(hibernate.enabled, isFalse);
    expect(find.text('Hibernate (unavailable)'), findsOneWidget);
  });
}

Widget _harness({
  required PowerButtonAction value,
  required bool hibernateAvailable,
}) {
  return MaterialApp(
    home: DenialLocalizationScope(
      locale: const Locale('en'),
      child: ShellTheme(
        data: const ShellThemeData(),
        child: Material(
          child: SizedBox(
            width: 800,
            child: SettingsPowerButtonActionSelector(
              value: value,
              hibernateAvailable: hibernateAvailable,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}
