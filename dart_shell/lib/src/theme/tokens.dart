import 'package:flutter/widgets.dart';

/// Centralised colour palette for the shell.
///
/// Names are semantic rather than literal so the same token can be retuned in
/// one place. Values are preserved exactly from the original inline literals.
abstract final class ShellColors {
  static const Color background = Color(0xff0f1115);

  // Material 3 dark surface roles, tuned for the translucent shell surfaces.
  static const Color surfaceContainerLow = Color(0xf21a1d23);
  static const Color surfaceContainer = Color(0xf222262d);
  static const Color surfaceContainerHigh = Color(0xf52a2f38);
  static const Color surfaceContainerHighest = Color(0xf6343a45);
  static const Color surfaceTint = Color(0x26d0bcff);

  /// Primary "ice white" foreground used across the status bar and labels.
  static const Color textPrimary = Color(0xfff4eff4);

  /// Panel-tinted white used inside the quick-settings shade.
  static const Color panelText = Color(0xfff4eff4);
  static const Color textSecondary = Color(0xffcac4d0);
  static const Color textTertiary = Color(0xffa9a3af);

  /// Brand accent ("Synthia" purple).
  static const Color accent = Color(0xffd0bcff);
  static const Color lockAccent = Color(0xff78dce8);
  static const Color onAccent = Color(0xff381e72);
  static const Color primaryContainer = Color(0xff4f378b);
  static const Color onPrimaryContainer = Color(0xffeaddff);
  static const Color onPrimaryContainerSecondary = Color(0xcceaddff);
  static const Color secondaryContainer = Color(0xff4a4458);
  static const Color onSecondaryContainer = Color(0xffe8def8);

  static const Color panelBackground = Color(0xee14171d);
  static const Color panelBackgroundBottom = Color(0xf21b1f27);
  static const Color panelHighlight = Color(0x1fffffff);
  static const Color tileOff = surfaceContainerHigh;
  static const Color tileIcon = surfaceContainerHighest;
  static const Color tileIconActive = Color(0x26eaddff);
  static const Color chip = surfaceContainerHigh;
  static const Color overviewScrim = Color(0xb2050608);

  // Hairlines / borders.
  static const Color hairline = Color(0x3d938f99);
  static const Color hairlineSoft = Color(0x26938f99);
  static const Color hairlineWindow = Color(0x2effffff);
  static const Color windowFrameSurface = Color(0xff1a1d23);
  static const Color focusedWindowBorder = primaryContainer;
  static const Color pinnedWindowBorder = Color(0xff432f76);

  // Shadows.
  static const Color shadow = Color(0x76000000);
  static const Color shadowSoft = Color(0x66000000);

  // Slider internals.
  static const Color sliderThumb = Color(0xf2f8fbff);
  static const Color sliderIconDark = onAccent;
  static const Color brightnessTrack = surfaceContainerHighest;
  static const Color volumeTrack = surfaceContainerHighest;
  static const Color wallpaperEffectTrack = surfaceContainerHighest;

  // Gesture pill.
  static const Color gestureArmed = Color(0xff8ee6c1);
  static const Color gesturePill = Color(0xdff7f7f8);

  // App launch transition.
  static const Color launchSurface = Color(0xff000000);
  static const Color fallbackAppIcon = Color(0xff147cdc);

  // Frame diagnostics.
  static const Color performanceGood = gestureArmed;
  static const Color performanceWarning = Color(0xffffcc66);
  static const Color performanceBad = Color(0xffff5c6c);

  // Status glyphs.
  static const Color glyphInactive = Color(0x66f7f7f8);
}

/// Default opacity for the shell's frosted surfaces.
abstract final class ShellOpacity {
  static const double panel = 0.75;
}

/// Corner radii used throughout the shell.
abstract final class ShellRadii {
  static const double window = 8.0;
  static const double notification = 18.0;
  static const double tile = 24.0;
  static const double tileWide = 24.0;
  static const double panel = 28.0;
  static const double chip = 21.0;
  static const double roundButton = 21.0;
}

/// Shared text styles. All disable the default underline decoration so callers
/// never have to repeat `decoration: TextDecoration.none`.
abstract final class ShellText {
  /// Monospace family bundled for the system bar so ticking values keep a
  /// fixed advance; the rest of the shell stays on the default family.
  static const String systemBarFontFamily = 'JetBrainsMono';
  static const List<String> fallbackFontFamilies = <String>[
    'Source Han Sans CN',
    'Noto Sans CJK SC',
  ];

  static const TextStyle base = TextStyle(
    color: ShellColors.textPrimary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 14,
    decoration: TextDecoration.none,
  );

  static const TextStyle statusClock = TextStyle(
    color: ShellColors.textPrimary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 18,
    height: 1,
    fontWeight: FontWeight.w800,
    decoration: TextDecoration.none,
  );

  /// System bar card text, sized for the thin pill cards floating inside the
  /// reserved bar strip.
  static const TextStyle systemBarValue = TextStyle(
    color: ShellColors.textPrimary,
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
    color: ShellColors.textSecondary,
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
    color: ShellColors.panelText,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 42,
    height: 1,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle shadeDate = TextStyle(
    color: ShellColors.textSecondary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 16,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockClock = TextStyle(
    color: ShellColors.textPrimary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 124,
    height: 0.95,
    fontWeight: FontWeight.w300,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockDate = TextStyle(
    color: ShellColors.textSecondary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 24,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockStatus = TextStyle(
    color: ShellColors.textSecondary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 18,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle lockChip = TextStyle(
    color: ShellColors.textPrimary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 12,
    height: 1,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    decoration: TextDecoration.none,
  );

  static const TextStyle cardTitle = TextStyle(
    color: ShellColors.textPrimary,
    fontFamilyFallback: fallbackFontFamilies,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    decoration: TextDecoration.none,
  );
}
