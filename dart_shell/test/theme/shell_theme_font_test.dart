import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('custom font family is applied to shell and Material text', () {
    const theme = ShellThemeData(fontFamily: 'Noto Sans');

    expect(theme.text.base.fontFamily, 'Noto Sans');
    expect(theme.text.systemBarValue.fontFamily, 'Noto Sans');
    expect(
      theme.toMaterialTheme().textTheme.bodyMedium?.fontFamily,
      'Noto Sans',
    );
  });

  test('font family participates in theme identity and interpolation', () {
    const system = ShellThemeData();
    const custom = ShellThemeData(fontFamily: 'Noto Sans');

    expect(system, isNot(custom));
    expect(ShellThemeData.lerp(system, custom, 0.75).fontFamily, 'Noto Sans');
  });
}
