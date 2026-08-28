import 'package:flutter/widgets.dart';

/// Product colors whose identity is independent of surface brightness.
abstract final class ShellBrandColors {
  static const Color defaultAccent = Color(0xffd0bcff);
  static const Color fallbackAppIcon = Color(0xff147cdc);

  /// Source foreground embedded in the Denial SVG wordmark. The SVG loader
  /// replaces this sentinel with the active semantic text foreground.
  static const Color wordmarkAssetForeground = Color(0xfff0eef5);
}

/// Colors for shell content deliberately composited over imagery.
///
/// These roles do not follow desktop brightness: their callers provide a dark
/// glass or scrim so clocks, launcher labels, and media annotations retain a
/// stable foreground over arbitrary wallpaper and application content.
abstract final class ShellMediaColors {
  static const Color lightForeground = Color(0xfff7f7f8);
  static const Color contrastLight = Color(0xffffffff);
  static const Color lightForegroundSecondary = Color(0xffc7c9d1);
  static const Color lightForegroundTertiary = Color(0xff8f96a3);
  static const Color darkSurface = Color(0xff070910);
  static const Color glassSurface = Color(0x28070910);
  static const Color glassSurfaceStrong = Color(0xdd070910);
  static const Color lightOutline = Color(0x26ffffff);
  static const Color lightGrid = Color(0x24ffffff);
  static const Color wallpaperScrim = Color(0x14000000);
  static const Color darkness = Color(0xff000000);
  static const Color shadow = Color(0x80000000);
  static const Color transparentDark = Color(0x00000000);
  static const Color transparentLight = Color(0x00ffffff);
}

/// Invariant telemetry colors whose hue communicates a native device state.
abstract final class ShellTelemetryColors {
  static const Color chargingVooc = Color(0xff5ff38a);
  static const Color chargingPps = Color(0xffbd8cff);
  static const Color chargingPd = Color(0xff7aa8ff);
  static const Color charging = Color(0xff78dce8);
  static const Color warning = Color(0xffffd166);
  static const Color danger = Color(0xffff6b6b);
  static const Color discharge = Color(0xffffa657);
  static const Color warm = Color(0xffffb86b);
  static const Color nominal = Color(0xff8ee6c1);
}

/// Default opacity for the shell's frosted surfaces.
abstract final class ShellOpacity {
  static const double panel = 0.75;
  static const double card = 0.95;
  static const double minimumPanel = 0.05;
  static const double minimumCard = 0;
}

/// Global scale applied to every semantic shell corner radius.
///
/// A scale keeps the visual hierarchy between windows, panels, cards, chips,
/// and controls while giving users one coherent roundness control. A value of
/// zero makes every themed corner square.
abstract final class ShellRoundness {
  static const double normal = 1.0;
  static const double minimum = 0.0;
  static const double maximum = 2.0;
}

/// Base corner radii used throughout the shell at normal roundness.
abstract final class ShellRadii {
  /// Windows and panels are peer top-level surfaces and must share one shape.
  static const double panel = 28.0;
  static const double window = panel;
  static const double notification = 18.0;
  static const double tile = 24.0;
  static const double tileWide = 24.0;
  static const double chip = 21.0;
  static const double roundButton = 21.0;
}

/// Brightness-independent text metrics.
///
/// [ShellTextTheme] applies semantic foreground colors. Keeping these
/// prototypes colorless lets text inherit the active shell foreground when a
/// specialized resolved style is unnecessary.
abstract final class ShellText {
  /// Monospace family bundled for the system bar so ticking values keep a
  /// fixed advance; the rest of the shell stays on the default family.
  static const String systemBarFontFamily = 'JetBrainsMono';
  static const List<String> fallbackFontFamilies = <String>[
    'Source Han Sans CN',
    'Noto Sans CJK SC',
  ];

  static const TextStyle base = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 14,
    decoration: TextDecoration.none,
  );

  static const TextStyle statusClock = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 18,
    height: 1,
    fontWeight: FontWeight.w800,
    decoration: TextDecoration.none,
  );

  /// System bar card text, sized for the thin pill cards floating inside the
  /// reserved bar strip.
  static const TextStyle systemBarValue = TextStyle(
    fontFamily: systemBarFontFamily,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 13,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    decoration: TextDecoration.none,
  );

  /// Secondary system bar text (the date caption beside the clock). Callers
  /// tint the color toward the wallpaper accent.
  static const TextStyle systemBarCaption = TextStyle(
    fontFamily: systemBarFontFamily,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 11,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    decoration: TextDecoration.none,
  );

  static const TextStyle shadeClock = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 42,
    height: 1,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle shadeDate = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 16,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockClock = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 124,
    height: 0.95,
    fontWeight: FontWeight.w300,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockDate = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 24,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockStatus = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 18,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockChip = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 12,
    height: 1,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle cardTitle = TextStyle(
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    decoration: TextDecoration.none,
  );
}
