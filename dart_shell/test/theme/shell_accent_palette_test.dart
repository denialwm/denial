import 'dart:io';

import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every accent role is derived from the configured shell accent', () {
    const teal = Color(0xff28d7bd);
    const orange = Color(0xffff9d36);
    final tealPalette = ShellAccentPalette.from(teal);
    final orangePalette = ShellAccentPalette.from(orange);

    expect(tealPalette.primary, isNot(orangePalette.primary));
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

  test('extreme seeds remain readable in both brightness schemes', () {
    const seeds = <Color>[
      Color(0xff000000),
      Color(0xffffffff),
      Color(0xffff0000),
      Color(0xffffd54f),
      Color(0xff777777),
    ];
    for (final scheme in const <ShellColorScheme>[
      ShellColorScheme.dark,
      ShellColorScheme.light,
    ]) {
      for (final seed in seeds) {
        final palette = ShellAccentPalette.from(seed, scheme);
        expect(
          _contrast(palette.primary, palette.onPrimary),
          greaterThanOrEqualTo(4.5),
          reason: '$seed on ${scheme.brightness}',
        );
        expect(
          _contrast(palette.container, palette.onContainer),
          greaterThanOrEqualTo(4.5),
          reason: '$seed container on ${scheme.brightness}',
        );
        expect(
          _contrast(palette.mutedContainer, palette.onMutedContainer),
          greaterThanOrEqualTo(4.5),
          reason: '$seed muted container on ${scheme.brightness}',
        );
      }
    }
  });

  test('the same seed resolves to brightness-specific accent roles', () {
    const seed = Color(0xff28d7bd);
    final dark = ShellAccentPalette.from(seed);
    final light = ShellAccentPalette.from(seed, ShellColorScheme.light);

    expect(dark.primary, isNot(light.primary));
    expect(dark.container, isNot(light.container));
  });

  test('theme interpolation blends accent roles without a brightness jump', () {
    const dark = ShellThemeData(
      colors: ShellColorScheme.dark,
      accent: Color(0xff00ff00),
    );
    const light = ShellThemeData(
      colors: ShellColorScheme.light,
      accent: Color(0xffff00ff),
    );

    expect(
      ShellThemeData.lerp(dark, light, 0).accentPalette.primary,
      dark.accentPalette.primary,
    );
    expect(
      ShellThemeData.lerp(dark, light, 1).accentPalette.primary,
      light.accentPalette.primary,
    );
    final before = ShellThemeData.lerp(dark, light, 0.49).accentPalette.primary;
    final after = ShellThemeData.lerp(dark, light, 0.51).accentPalette.primary;
    expect(_channelDistance(before, after), lessThan(0.08));
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

double _channelDistance(Color first, Color second) {
  return (first.r - second.r).abs() +
      (first.g - second.g).abs() +
      (first.b - second.b).abs();
}
