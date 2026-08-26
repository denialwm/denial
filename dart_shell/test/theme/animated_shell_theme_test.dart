import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('zero-duration theme changes apply in one frame', (tester) async {
    var initializations = 0;
    Brightness? observedBrightness;
    const probe = _ThemeProbe(key: ValueKey('persistent-theme-probe'));

    Widget application(ShellColorScheme colors) {
      return MaterialApp(
        home: AnimatedShellTheme(
          data: ShellThemeData(colors: colors),
          duration: Duration.zero,
          child: _ThemeProbeHost(
            probe: probe,
            onInitialize: () => initializations += 1,
            onBuild: (brightness) => observedBrightness = brightness,
          ),
        ),
      );
    }

    await tester.pumpWidget(application(ShellColorScheme.dark));
    expect(observedBrightness, Brightness.dark);
    expect(initializations, 1);

    await tester.pumpWidget(application(ShellColorScheme.light));
    await tester.pump();

    expect(observedBrightness, Brightness.light);
    expect(initializations, 1);
  });

  testWidgets('theme interpolation stays within the configured transition', (
    tester,
  ) async {
    ShellThemeData? observedTheme;

    Widget application(ShellColorScheme colors) {
      return MaterialApp(
        home: AnimatedShellTheme(
          data: ShellThemeData(colors: colors),
          duration: const Duration(milliseconds: 200),
          child: Builder(
            builder: (context) {
              observedTheme = context.shellTheme;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    }

    await tester.pumpWidget(application(ShellColorScheme.dark));
    await tester.pumpWidget(application(ShellColorScheme.light));
    await tester.pump(const Duration(milliseconds: 100));

    expect(observedTheme, isNotNull);
    expect(observedTheme!.colors, isNot(ShellColorScheme.dark));
    expect(observedTheme!.colors, isNot(ShellColorScheme.light));

    await tester.pump(const Duration(milliseconds: 100));
    expect(observedTheme!.colors, ShellColorScheme.light);
  });

  testWidgets('default text follows the interpolated semantic theme', (
    tester,
  ) async {
    Color? observedColor;

    Widget application(ShellColorScheme colors) {
      return MaterialApp(
        home: AnimatedShellTheme(
          data: ShellThemeData(colors: colors),
          duration: const Duration(milliseconds: 200),
          child: ShellDefaultTextStyle(
            child: Builder(
              builder: (context) {
                observedColor = DefaultTextStyle.of(context).style.color;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(application(ShellColorScheme.dark));
    final darkColor = observedColor;
    await tester.pumpWidget(application(ShellColorScheme.light));
    await tester.pump(const Duration(milliseconds: 100));

    expect(observedColor, isNot(darkColor));
    expect(observedColor, isNot(ShellColorScheme.light.textPrimary));

    await tester.pump(const Duration(milliseconds: 100));
    expect(observedColor, ShellColorScheme.light.textPrimary);
  });
}

class _ThemeProbeHost extends StatelessWidget {
  const _ThemeProbeHost({
    required this.probe,
    required this.onInitialize,
    required this.onBuild,
  });

  final _ThemeProbe probe;
  final VoidCallback onInitialize;
  final ValueChanged<Brightness> onBuild;

  @override
  Widget build(BuildContext context) {
    return _ThemeProbe(
      key: probe.key,
      onInitialize: onInitialize,
      onBuild: onBuild,
    );
  }
}

class _ThemeProbe extends StatefulWidget {
  const _ThemeProbe({super.key, this.onInitialize, this.onBuild});

  final VoidCallback? onInitialize;
  final ValueChanged<Brightness>? onBuild;

  @override
  State<_ThemeProbe> createState() => _ThemeProbeState();
}

class _ThemeProbeState extends State<_ThemeProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInitialize?.call();
  }

  @override
  Widget build(BuildContext context) {
    widget.onBuild?.call(context.shellTheme.brightness);
    return const SizedBox.shrink();
  }
}
