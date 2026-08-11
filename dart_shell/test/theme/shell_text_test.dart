import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every shell text token carries the CJK fallback chain', () {
    const styles = <TextStyle>[
      ShellText.base,
      ShellText.statusClock,
      ShellText.systemBarValue,
      ShellText.systemBarCaption,
      ShellText.shadeClock,
      ShellText.shadeDate,
      ShellText.lockClock,
      ShellText.lockDate,
      ShellText.lockStatus,
      ShellText.lockChip,
      ShellText.cardTitle,
    ];

    for (final style in styles) {
      expect(
        style.fontFamilyFallback,
        ShellText.fallbackFontFamilies,
        reason: style.toString(),
      );
    }
  });
}
