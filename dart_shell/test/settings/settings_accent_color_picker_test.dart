import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/widgets/focused_border_color_picker.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_color_value_editor.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exact color controls remain available in a short picker', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Color? changed;

    await tester.pumpWidget(
      MaterialApp(
        home: DenialLocalizationScope(
          locale: const Locale('en'),
          child: ShellTheme(
            data: const ShellThemeData(),
            child: Material(
              child: SettingsAccentColorPicker(
                color: const Color(0xff8040c0),
                onChanged: (color) => changed = color,
                onReset: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(settingsColorInputRgbKey), findsOneWidget);

    await tester.ensureVisible(find.byKey(settingsColorInputRedFieldKey));
    await tester.enterText(find.byKey(settingsColorInputRedFieldKey), '20');
    await tester.enterText(find.byKey(settingsColorInputGreenFieldKey), '40');
    await tester.enterText(find.byKey(settingsColorInputBlueFieldKey), '60');
    await tester.pump();

    expect(changed, const Color(0xff14283c));
    expect(tester.takeException(), isNull);
  });
}
