import 'package:denial_dart_shell/src/config/startup_environment.dart';
import 'package:denial_dart_shell/src/state/cursor_theme.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Bibata Modern Ice is the desktop default', () {
    final container = ProviderContainer.test();

    expect(
      container.read(shellCursorThemeProvider),
      same(ShellCursorThemes.bibataModernIce),
    );
  });

  test('Bibata is the only bundled cursor theme', () {
    expect(ShellCursorThemes.all, <ShellCursorThemeData>[
      ShellCursorThemes.bibataModernIce,
    ]);
  });

  test('unknown startup themes fail safely to Bibata', () {
    final container = ProviderContainer.test(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(
          StartupEnvironment(const <String, String>{
            'DENIA_CURSOR_THEME': 'not-a-theme',
          }),
        ),
      ],
    );

    expect(
      container.read(shellCursorThemeProvider),
      same(ShellCursorThemes.bibataModernIce),
    );
  });
}
