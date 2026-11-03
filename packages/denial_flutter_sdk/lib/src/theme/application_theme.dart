import 'package:flutter/material.dart';

import 'application_material_policy.dart';
import 'glass_configuration.dart';
import 'shell_theme.dart';

/// Denial's application palette: related opaque and translucent surfaces.
/// These colors are intentionally independent of the user's accent seed.
@immutable
class DenialApplicationColors {
  const DenialApplicationColors._({
    required this.canvas,
    required this.raised,
    required this.control,
    required this.chrome,
    required this.foreground,
    required this.secondary,
    required this.separator,
  });

  factory DenialApplicationColors.forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static const dark = DenialApplicationColors._(
    canvas: Color(0xff22211f),
    raised: Color(0xff2c2b29),
    control: Color(0xff383734),
    chrome: Color(0xff000000),
    foreground: Color(0xfff2f1ef),
    secondary: Color(0xffbbb9b5),
    separator: Color(0x24b5b2ab),
  );
  static const light = DenialApplicationColors._(
    canvas: Color(0xfff7f6f3),
    raised: Color(0xffffffff),
    control: Color(0xffeeece7),
    chrome: Color(0xffffffff),
    foreground: Color(0xff292825),
    secondary: Color(0xff625f59),
    separator: Color(0x28625f59),
  );

  final Color canvas;
  final Color raised;
  final Color control;
  final Color chrome;
  final Color foreground;
  final Color secondary;
  final Color separator;
}

/// Opt-in application theme. Shell panels retain their existing material API.
/// Functional overlays follow application appearance for stable foreground
/// contrast as they span the revealed desktop and the opaque content surface.
@immutable
class DenialApplicationTheme {
  DenialApplicationTheme._(this.shell);
  static final _cache = Expando<DenialApplicationTheme>();
  factory DenialApplicationTheme.fromShell(ShellThemeData shell) =>
      _cache[shell] ??= DenialApplicationTheme._(shell);
  static DenialApplicationTheme of(BuildContext context) =>
      DenialApplicationTheme.fromShell(ShellTheme.of(context));

  final ShellThemeData shell;
  late final colors = DenialApplicationColors.forBrightness(shell.brightness);
  late final materialTheme = _materialTheme(shell, colors);

  DenialMaterialPolicy policy(DenialMaterialRole role) =>
      DenialMaterialPolicy.resolve(
        role: role,
        transparency: shell.transparencyMode,
        // One key for the backing behind apps, in glass and blur alike.
        windowOpacity: shell.glass.windowOpacity,
        appPanelOpacity: shell.transparencyMode == ShellTransparencyMode.glass
            ? shell.glass.appPanelOpacity
            : shell.effectivePanelOpacity,
      );

  Color background(DenialMaterialRole role) {
    final palette = colors;
    final opacity = policy(role).opacity;
    final color = switch (role) {
      DenialMaterialRole.window =>
        opacity == 1 ? palette.canvas : palette.chrome,
      DenialMaterialRole.sidebar ||
      DenialMaterialRole.toolbar => palette.chrome,
      DenialMaterialRole.card ||
      DenialMaterialRole.dialog ||
      DenialMaterialRole.popover => palette.raised,
      _ => palette.canvas,
    };
    // Functional glass uses a neutral black/white tint; opaque content keeps
    // its own warm palette. Window backing and functional panels have separate
    // opacity controls; neither changes the alpha of their foreground content.
    return color.withValues(alpha: opacity);
  }

  static ThemeData _materialTheme(
    ShellThemeData shell,
    DenialApplicationColors colors,
  ) {
    final base = shell.toMaterialTheme();
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        surface: colors.canvas,
        onSurface: colors.foreground,
        onSurfaceVariant: colors.secondary,
        surfaceContainerLow: colors.raised,
        surfaceContainer: colors.raised,
        surfaceContainerHigh: colors.control,
        surfaceContainerHighest: colors.control,
        outlineVariant: colors.separator,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: colors.foreground,
        displayColor: colors.foreground,
      ),
      iconTheme: base.iconTheme.copyWith(color: colors.foreground),
      dividerColor: colors.separator,
      cardTheme: base.cardTheme.copyWith(
        color: colors.raised,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: colors.raised,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        color: colors.raised,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: colors.control,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}

extension DenialApplicationThemeContext on BuildContext {
  DenialApplicationTheme get applicationTheme =>
      DenialApplicationTheme.of(this);
  DenialApplicationColors get applicationColors => applicationTheme.colors;
}
