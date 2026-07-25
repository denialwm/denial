import 'dart:io';

import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every accent role is derived from the configured shell accent', () {
    const teal = Color(0xff28d7bd);
    const orange = Color(0xffff9d36);
    final tealPalette = ShellAccentPalette.from(teal);
    final orangePalette = ShellAccentPalette.from(orange);

    expect(tealPalette.primary, teal);
    expect(orangePalette.primary, orange);
    expect(tealPalette.container, isNot(orangePalette.container));
    expect(tealPalette.mutedContainer, isNot(orangePalette.mutedContainer));
    expect(tealPalette.outline, isNot(orangePalette.outline));
    expect(tealPalette.selection, isNot(orangePalette.selection));
    expect(
      _contrast(tealPalette.primary, tealPalette.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(tealPalette.container, tealPalette.onContainer),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(tealPalette.mutedContainer, tealPalette.onMutedContainer),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('accent-owned surfaces cannot reference legacy accent colors', () {
    const guardedSourceFiles = <String>[
      'lib/src/desktop/desktop_shell.dart',
      'lib/src/widgets/lock/lock_screen_layer.dart',
    ];
    const guardedSourceDirectories = <String>[
      'lib/src/widgets/session',
      'lib/src/wallpaper/widgets',
    ];
    const forbiddenReferences = <String>[
      'ShellColors.accent',
      'ShellColors.onAccent',
      'ShellColors.primaryContainer',
      'ShellColors.onPrimaryContainer',
      'ShellColors.onPrimaryContainerSecondary',
      'ShellColors.secondaryContainer',
      'ShellColors.onSecondaryContainer',
      'ShellColors.lockAccent',
      'ShellColors.focusedWindowBorder',
      'ShellColors.pinnedWindowBorder',
      'ShellColors.surfaceTint',
      'ShellColors.tileIconActive',
      'Colors.purple',
      '0xffd0bcff',
      '0xff381e72',
      '0xff4f378b',
      '0xffeaddff',
      '0xcceaddff',
      '0xff4a4458',
      '0xffe8def8',
      '0xff432f76',
      '0xffbd8cff',
    ];

    final guardedSources = <File>[
      for (final path in guardedSourceFiles) File(path),
      for (final directory in guardedSourceDirectories)
        ...Directory(directory)
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
    ];

    for (final file in guardedSources) {
      final path = file.path;
      final source = file.readAsStringSync().toLowerCase();
      for (final forbidden in forbiddenReferences) {
        expect(
          source,
          isNot(contains(forbidden.toLowerCase())),
          reason:
              '$path must derive accent roles from '
              'ShellTheme.of(context).accentPalette; found $forbidden',
        );
      }
    }
  });
}

double _contrast(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
