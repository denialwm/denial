import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scheme in const <ShellColorScheme>[
    ShellColorScheme.dark,
    ShellColorScheme.light,
  ]) {
    test('${scheme.brightness.name} semantic foregrounds remain readable', () {
      for (final surface in <Color>[
        scheme.background,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
        scheme.panelBackground,
        scheme.panelBackgroundBottom,
      ]) {
        final composite = Color.alphaBlend(surface, scheme.background);
        expect(
          _contrast(scheme.textPrimary, composite),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(scheme.textSecondary, composite),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(scheme.textTertiary, composite),
          greaterThanOrEqualTo(3.0),
        );
      }
    });
  }

  test('theme interpolation preserves exact endpoints', () {
    const dark = ShellThemeData(colors: ShellColorScheme.dark);
    const light = ShellThemeData(colors: ShellColorScheme.light);

    expect(identical(ShellThemeData.lerp(dark, light, 0), dark), isTrue);
    expect(identical(ShellThemeData.lerp(dark, light, 1), light), isTrue);
    expect(ShellThemeData.lerp(dark, light, 0.49).brightness, Brightness.dark);
    expect(ShellThemeData.lerp(dark, light, 0.51).brightness, Brightness.light);
  });

  test('derived theme objects are cached by immutable theme identity', () {
    const theme = ShellThemeData(colors: ShellColorScheme.dark);

    expect(identical(theme.text, theme.text), isTrue);
    expect(identical(theme.accentPalette, theme.accentPalette), isTrue);
    expect(
      identical(theme.backdropBlurFilterConfig, theme.backdropBlurFilterConfig),
      isTrue,
    );
    expect(identical(theme.toMaterialTheme(), theme.toMaterialTheme()), isTrue);
  });

  test('geometry-only interpolation reuses semantic color derivations', () {
    const first = ShellThemeData(windowRadius: 4);
    const second = ShellThemeData(windowRadius: 28);
    final interpolated = ShellThemeData.lerp(first, second, 0.5);

    expect(identical(interpolated.colors, first.colors), isTrue);
    expect(identical(interpolated.text, first.text), isTrue);
    expect(identical(interpolated.accentPalette, first.accentPalette), isTrue);
    expect(
      identical(
        interpolated.backdropBlurFilterConfig,
        first.backdropBlurFilterConfig,
      ),
      isTrue,
    );
    expect(
      identical(
        ShellColorScheme.lerp(first.colors, second.colors, 0.5),
        first.colors,
      ),
      isTrue,
    );
  });

  test('light theme keeps the complete dark unfocused window frame pair', () {
    expect(
      ShellColorScheme.light.hairlineWindow,
      ShellColorScheme.dark.hairlineWindow,
    );
    expect(
      ShellColorScheme.light.windowFrameSurface,
      ShellColorScheme.dark.windowFrameSurface,
    );
  });

  for (final scheme in const <ShellColorScheme>[
    ShellColorScheme.dark,
    ShellColorScheme.light,
  ]) {
    test(
      '${scheme.brightness.name} panel backing survives worst wallpaper',
      () {
        final theme = ShellThemeData(colors: scheme, panelOpacity: 0.35);
        final wallpaper = scheme.brightness == Brightness.dark
            ? const Color(0xffffffff)
            : const Color(0xff000000);
        final panel = Color.alphaBlend(
          theme.panelColor(scheme.panelBackground),
          wallpaper,
        );

        expect(_contrast(scheme.textPrimary, panel), greaterThanOrEqualTo(4.5));
        expect(
          _contrast(scheme.textSecondary, panel),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(scheme.textTertiary, panel),
          greaterThanOrEqualTo(3.0),
        );
        expect(theme.effectivePanelOpacity, greaterThan(theme.panelOpacity));
      },
    );
  }
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
