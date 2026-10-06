import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_color_value_editor.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('RGB channels apply an exact opaque color live', (tester) async {
    Color? changed;
    await tester.pumpWidget(
      _ColorEditorHarness(onChanged: (color) => changed = color),
    );

    await tester.enterText(find.byKey(settingsColorInputRedFieldKey), '12');
    await tester.enterText(find.byKey(settingsColorInputGreenFieldKey), '34');
    await tester.enterText(find.byKey(settingsColorInputBlueFieldKey), '56');
    await tester.pump();

    expect(changed, const Color(0xff0c2238));
  });

  testWidgets('HSL and shorthand hex are first-class input modes', (
    tester,
  ) async {
    Color? changed;
    await tester.pumpWidget(
      _ColorEditorHarness(onChanged: (color) => changed = color),
    );

    await tester.tap(find.byKey(settingsColorInputHslKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(settingsColorInputHueFieldKey), '0');
    await tester.enterText(
      find.byKey(settingsColorInputSaturationFieldKey),
      '100',
    );
    await tester.enterText(
      find.byKey(settingsColorInputLightnessFieldKey),
      '50',
    );
    await tester.pump();
    expect(changed, const Color(0xffff0000));

    await tester.tap(find.byKey(settingsColorInputHexKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(settingsColorInputHexFieldKey), '#3af');
    await tester.pump();
    expect(changed, const Color(0xff33aaff));
  });

  testWidgets('invalid RGB values explain the accepted range', (tester) async {
    Color? changed;
    await tester.pumpWidget(
      _ColorEditorHarness(onChanged: (color) => changed = color),
    );

    await tester.enterText(find.byKey(settingsColorInputRedFieldKey), '999');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    expect(changed, isNull);
    expect(find.text('Use RGB values from 0 to 255.'), findsOneWidget);
  });

  testWidgets('arrow keys nudge a focused channel', (tester) async {
    Color? changed;
    await tester.pumpWidget(
      _ColorEditorHarness(onChanged: (color) => changed = color),
    );

    await tester.tap(find.byKey(settingsColorInputRedFieldKey));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(changed, const Color(0xff8140c0));
    final field = tester.widget<TextField>(
      find.byKey(settingsColorInputRedFieldKey),
    );
    expect(field.controller?.text, '129');
  });

  testWidgets('channel labels stay above the input outline', (tester) async {
    await tester.pumpWidget(_ColorEditorHarness(onChanged: (_) {}));

    final labelRect = tester.getRect(find.text('Red'));
    final fieldFinder = find.byKey(settingsColorInputRedFieldKey);
    final fieldRect = tester.getRect(fieldFinder);
    final field = tester.widget<TextField>(fieldFinder);

    expect(labelRect.bottom, lessThan(fieldRect.top));
    expect(field.decoration?.labelText, isNull);
  });
}

class _ColorEditorHarness extends StatefulWidget {
  const _ColorEditorHarness({required this.onChanged});

  final ValueChanged<Color> onChanged;

  @override
  State<_ColorEditorHarness> createState() => _ColorEditorHarnessState();
}

class _ColorEditorHarnessState extends State<_ColorEditorHarness> {
  var _color = const Color(0xff8040c0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DenialLocalizationScope(
        locale: const Locale('en'),
        child: ShellTheme(
          data: const ShellThemeData(),
          child: Material(
            child: Center(
              child: SizedBox(
                width: 360,
                child: SettingsColorValueEditor(
                  color: _color,
                  onChanged: (color) {
                    widget.onChanged(color);
                    setState(() => _color = color);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
