import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/osk/shell_osk_panel.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Backspace hold emits one balanced native key lifecycle', (
    tester,
  ) async {
    final intents = <ShellOskKeyIntent>[];
    var haptics = 0;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: ShellTheme(
          data: const ShellThemeData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(420, 340)),
              child: SizedBox(
                width: 420,
                height: 340,
                child: ShellOskPanel(
                  onKey: intents.add,
                  onKeyTap: () => haptics += 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final backspace = find.byIcon(Icons.backspace_rounded);
    expect(backspace, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(backspace));
    await tester.pump();

    expect(intents, hasLength(1));
    expect(intents.single.action, ShellOskKeyAction.backspace);
    expect(intents.single.phase, ShellOskKeyPhase.pressed);
    expect(haptics, 1);

    // Flutter owns the touch lifecycle, not repeat timing. Rust's ordinary
    // desktop keyboard path generates repeats while this press remains held.
    await tester.pump(const Duration(seconds: 1));
    expect(intents, hasLength(1));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(intents, hasLength(2));
    expect(intents.last.action, ShellOskKeyAction.backspace);
    expect(intents.last.phase, ShellOskKeyPhase.released);
    expect(haptics, 1);
  });
}
