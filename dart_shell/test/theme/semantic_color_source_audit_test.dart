import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('static interface colours stay inside the semantic theme boundary', () {
    const allowedSources = <String>{
      'lib/src/theme/shell_color_scheme.dart',
      'lib/src/theme/tokens.dart',
      // The fixed RGB stops describe the HSV gamut itself, not shell chrome.
      'lib/src/settings/widgets/hsv_color_wheel.dart',
    };
    final directColour = RegExp(
      r'\bColor\(0x|\bColors\.(?:black|white|red|green|blue|yellow|orange|purple|grey|gray|transparent)\b',
    );
    final violations = <String>[];

    for (final entity in Directory('lib/src').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final path = entity.path.replaceAll('\\', '/');
      if (allowedSources.contains(path)) {
        continue;
      }
      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index += 1) {
        if (directColour.hasMatch(lines[index])) {
          violations.add('$path:${index + 1}: ${lines[index].trim()}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Put brightness-dependent colours in ShellColorScheme and name '
          'intentional brand, media, or telemetry colours in tokens.dart.',
    );
  });

  test('the legacy global ShellColors escape hatch stays removed', () {
    final violations = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      if (RegExp(r'\bShellColors\b').hasMatch(entity.readAsStringSync())) {
        violations.add(entity.path);
      }
    }
    expect(violations, isEmpty);
  });

  test('DefaultTextStyle never shadows the resolved semantic text theme', () {
    final violations = <String>[];
    final unresolvedDefault = RegExp(
      r'DefaultTextStyle\s*\(\s*style:\s*ShellText\.',
      multiLine: true,
    );
    for (final entity in Directory('lib/src').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      if (unresolvedDefault.hasMatch(entity.readAsStringSync())) {
        violations.add(entity.path);
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'ShellText contains colorless metric prototypes. Seed every '
          'DefaultTextStyle from context.shellTheme.text instead.',
    );
  });
}
