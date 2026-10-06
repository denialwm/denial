import 'package:denial_dart_shell/src/theme/shell_font_catalog.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog discovery always exposes Denial bundled font', () async {
    final families = await const ShellFontCatalog().discover();

    expect(families, contains(ShellText.systemBarFontFamily));
  });

  test('font families are normalized, deduplicated, and sorted', () {
    expect(
      normalizeShellFontFamilies(const <String>[
        ' Noto Sans ',
        'noto sans',
        'Zed Sans',
        '',
        'broken\u0000family',
      ]),
      const <String>[ShellText.systemBarFontFamily, 'Noto Sans', 'Zed Sans'],
    );
  });
}
