import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_displays_page.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('custom percentage is normalized and shown truthfully', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(_harness(onChanged: (scale) => changed = scale));

    await tester.enterText(find.byKey(settingsDisplayScaleFieldKey), '94');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(changed, closeTo(113 / 120, 0.000001));
    final field = tester.widget<TextField>(
      find.byKey(settingsDisplayScaleFieldKey),
    );
    expect(field.controller?.text, '94.17');
    expect(field.decoration?.errorText, isNull);
  });

  testWidgets('custom percentage rejects values outside 50 to 600', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(_harness(onChanged: (scale) => changed = scale));

    await tester.enterText(find.byKey(settingsDisplayScaleFieldKey), '49');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(changed, isNull);
    expect(find.text('Enter a value from 50 to 600.'), findsOneWidget);
  });

  testWidgets('wide layout keeps both controls compact and equally tall', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(onChanged: (_) {}));

    final inputSize = tester.getSize(find.byKey(settingsDisplayScaleInputKey));
    final presetSize = tester.getSize(
      find.byKey(settingsDisplayScalePresetKey),
    );
    expect(inputSize.width, 132);
    expect(presetSize.width, 176);
    expect(inputSize.height, presetSize.height);
  });

  testWidgets('common presets remain available as shortcuts', (tester) async {
    double? changed;
    await tester.pumpWidget(_harness(onChanged: (scale) => changed = scale));

    await tester.tap(find.byKey(settingsDisplayScalePresetKey));
    await tester.pump();
    final presetTap = tester.widget<GestureDetector>(
      find.ancestor(
        of: find.text('50%').last,
        matching: find.byType(GestureDetector),
      ),
    );
    presetTap.onTap!();
    await tester.pump();

    expect(changed, 0.5);
    final field = tester.widget<TextField>(
      find.byKey(settingsDisplayScaleFieldKey),
    );
    expect(field.controller?.text, '50');
  });
}

Widget _harness({required ValueChanged<double> onChanged}) {
  return MaterialApp(
    home: DenialLocalizationScope(
      locale: const Locale('en'),
      child: ShellTheme(
        data: const ShellThemeData(),
        child: Material(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 700,
              child: SettingsDisplayScaleControl(
                scale: 1,
                enabled: true,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
