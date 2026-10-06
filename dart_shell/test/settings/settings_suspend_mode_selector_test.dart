import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/suspend_mode.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_suspend_mode_selector.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a disabled select when Linux reports one mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        capabilities: SuspendModeCapabilities.parse('[s2idle]\n'),
        onChanged: (_) {},
      ),
    );

    final select = tester.widget<DropdownButton<SuspendMode>>(
      find.byType(DropdownButton<SuspendMode>),
    );
    expect(select.value, SuspendMode.s2idle);
    expect(select.onChanged, isNull);
    expect(find.text('Suspend to idle (s2idle)'), findsOneWidget);
  });

  testWidgets('enables the select when Linux reports multiple modes', (
    tester,
  ) async {
    SuspendMode? changed;
    await tester.pumpWidget(
      _harness(
        capabilities: SuspendModeCapabilities.parse('s2idle [deep]\n'),
        onChanged: (value) => changed = value,
      ),
    );

    final select = tester.widget<DropdownButton<SuspendMode>>(
      find.byType(DropdownButton<SuspendMode>),
    );
    expect(select.value, SuspendMode.deep);
    expect(select.onChanged, isNotNull);
    select.onChanged!(SuspendMode.s2idle);
    expect(changed, SuspendMode.s2idle);
  });
}

Widget _harness({
  required SuspendModeCapabilities capabilities,
  required ValueChanged<SuspendMode> onChanged,
}) {
  return MaterialApp(
    home: DenialLocalizationScope(
      locale: const Locale('en'),
      child: ShellTheme(
        data: const ShellThemeData(),
        child: Material(
          child: SizedBox(
            width: 800,
            child: SettingsSuspendModeSelector(
              capabilities: capabilities,
              preferredMode: SuspendMode.systemDefault,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    ),
  );
}
