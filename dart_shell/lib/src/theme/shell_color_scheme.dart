import 'package:flutter/widgets.dart';

/// Semantic colors for Denial-owned surfaces.
///
/// The dark values preserve the original shell palette. The light values are
/// independently tuned neutrals; the accent is resolved separately so a
/// wallpaper never recolors the complete surface stack.
@immutable
class ShellColorScheme {
  const ShellColorScheme({
    required this.brightness,
    required this.background,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.textPrimary,
    required this.panelText,
    required this.textSecondary,
    required this.textTertiary,
    required this.panelBackground,
    required this.panelBackgroundBottom,
    required this.panelHighlight,
    required this.tileOff,
    required this.tileIcon,
    required this.chip,
    required this.overviewScrim,
    required this.hairline,
    required this.hairlineSoft,
    required this.hairlineWindow,
    required this.windowFrameSurface,
    required this.shadow,
    required this.shadowSoft,
    required this.sliderThumb,
    required this.brightnessTrack,
    required this.volumeTrack,
    required this.wallpaperEffectTrack,
    required this.gestureArmed,
    required this.gesturePill,
    required this.launchSurface,
    required this.fallbackAppIcon,
    required this.performanceGood,
    required this.performanceWarning,
    required this.performanceBad,
    required this.glyphInactive,
  });

  static const ShellColorScheme dark = ShellColorScheme(
    brightness: Brightness.dark,
    background: Color(0xff0f1115),
    surfaceContainerLow: Color(0xf21a1d23),
    surfaceContainer: Color(0xf222262d),
    surfaceContainerHigh: Color(0xf52a2f38),
    surfaceContainerHighest: Color(0xf6343a45),
    textPrimary: Color(0xfff4eff4),
    panelText: Color(0xfff4eff4),
    textSecondary: Color(0xffcac4d0),
    textTertiary: Color(0xffa9a3af),
    panelBackground: Color(0xee14171d),
    panelBackgroundBottom: Color(0xf21b1f27),
    panelHighlight: Color(0x1fffffff),
    tileOff: Color(0xf52a2f38),
    tileIcon: Color(0xf6343a45),
    chip: Color(0xf52a2f38),
    overviewScrim: Color(0xb2050608),
    hairline: Color(0x3d938f99),
    hairlineSoft: Color(0x26938f99),
    hairlineWindow: Color(0x2effffff),
    windowFrameSurface: Color(0xff1a1d23),
    shadow: Color(0x76000000),
    shadowSoft: Color(0x66000000),
    sliderThumb: Color(0xf2f8fbff),
    brightnessTrack: Color(0xf6343a45),
    volumeTrack: Color(0xf6343a45),
    wallpaperEffectTrack: Color(0xf6343a45),
    gestureArmed: Color(0xff8ee6c1),
    gesturePill: Color(0xdff7f7f8),
    launchSurface: Color(0xff000000),
    fallbackAppIcon: Color(0xff147cdc),
    performanceGood: Color(0xff8ee6c1),
    performanceWarning: Color(0xffffcc66),
    performanceBad: Color(0xffff5c6c),
    glyphInactive: Color(0x66f7f7f8),
  );

  static const ShellColorScheme light = ShellColorScheme(
    brightness: Brightness.light,
    background: Color(0xfff7f7fb),
    surfaceContainerLow: Color(0xf2f1f1f7),
    surfaceContainer: Color(0xf2ebebf2),
    surfaceContainerHigh: Color(0xf5e4e4ec),
    surfaceContainerHighest: Color(0xf6dcdce6),
    textPrimary: Color(0xff1b1b21),
    panelText: Color(0xff1b1b21),
    textSecondary: Color(0xff45454f),
    textTertiary: Color(0xff686873),
    panelBackground: Color(0xeef5f5f9),
    panelBackgroundBottom: Color(0xf2eeeeF4),
    panelHighlight: Color(0x1f000000),
    tileOff: Color(0xf5e4e4ec),
    tileIcon: Color(0xf6dcdce6),
    chip: Color(0xf5e4e4ec),
    overviewScrim: Color(0x70050608),
    hairline: Color(0x52686873),
    hairlineSoft: Color(0x33686873),
    // The complete unfocused client frame pair intentionally matches dark
    // mode. Focus remains communicated by the independently painted accent
    // border.
    hairlineWindow: Color(0x2effffff),
    windowFrameSurface: Color(0xff1a1d23),
    shadow: Color(0x3d000000),
    shadowSoft: Color(0x29000000),
    sliderThumb: Color(0xffffffff),
    brightnessTrack: Color(0xf6dcdce6),
    volumeTrack: Color(0xf6dcdce6),
    wallpaperEffectTrack: Color(0xf6dcdce6),
    gestureArmed: Color(0xff176b51),
    gesturePill: Color(0xdf1b1b21),
    launchSurface: Color(0xfff7f7fb),
    fallbackAppIcon: Color(0xff0061a4),
    performanceGood: Color(0xff176b51),
    performanceWarning: Color(0xff7a5900),
    performanceBad: Color(0xffba1a1a),
    glyphInactive: Color(0x661b1b21),
  );

  final Brightness brightness;
  final Color background;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color textPrimary;
  final Color panelText;
  final Color textSecondary;
  final Color textTertiary;
  final Color panelBackground;
  final Color panelBackgroundBottom;
  final Color panelHighlight;
  final Color tileOff;
  final Color tileIcon;
  final Color chip;
  final Color overviewScrim;
  final Color hairline;
  final Color hairlineSoft;
  final Color hairlineWindow;
  final Color windowFrameSurface;
  final Color shadow;
  final Color shadowSoft;
  final Color sliderThumb;
  final Color brightnessTrack;
  final Color volumeTrack;
  final Color wallpaperEffectTrack;
  final Color gestureArmed;
  final Color gesturePill;
  final Color launchSurface;
  final Color fallbackAppIcon;
  final Color performanceGood;
  final Color performanceWarning;
  final Color performanceBad;
  final Color glyphInactive;

  static ShellColorScheme lerp(
    ShellColorScheme first,
    ShellColorScheme second,
    double t,
  ) {
    if (t <= 0) {
      return first;
    }
    if (t >= 1) {
      return second;
    }
    if (first == second) {
      return first;
    }
    Color blend(Color a, Color b) => Color.lerp(a, b, t)!;
    return ShellColorScheme(
      brightness: t < 0.5 ? first.brightness : second.brightness,
      background: blend(first.background, second.background),
      surfaceContainerLow: blend(
        first.surfaceContainerLow,
        second.surfaceContainerLow,
      ),
      surfaceContainer: blend(first.surfaceContainer, second.surfaceContainer),
      surfaceContainerHigh: blend(
        first.surfaceContainerHigh,
        second.surfaceContainerHigh,
      ),
      surfaceContainerHighest: blend(
        first.surfaceContainerHighest,
        second.surfaceContainerHighest,
      ),
      textPrimary: blend(first.textPrimary, second.textPrimary),
      panelText: blend(first.panelText, second.panelText),
      textSecondary: blend(first.textSecondary, second.textSecondary),
      textTertiary: blend(first.textTertiary, second.textTertiary),
      panelBackground: blend(first.panelBackground, second.panelBackground),
      panelBackgroundBottom: blend(
        first.panelBackgroundBottom,
        second.panelBackgroundBottom,
      ),
      panelHighlight: blend(first.panelHighlight, second.panelHighlight),
      tileOff: blend(first.tileOff, second.tileOff),
      tileIcon: blend(first.tileIcon, second.tileIcon),
      chip: blend(first.chip, second.chip),
      overviewScrim: blend(first.overviewScrim, second.overviewScrim),
      hairline: blend(first.hairline, second.hairline),
      hairlineSoft: blend(first.hairlineSoft, second.hairlineSoft),
      hairlineWindow: blend(first.hairlineWindow, second.hairlineWindow),
      windowFrameSurface: blend(
        first.windowFrameSurface,
        second.windowFrameSurface,
      ),
      shadow: blend(first.shadow, second.shadow),
      shadowSoft: blend(first.shadowSoft, second.shadowSoft),
      sliderThumb: blend(first.sliderThumb, second.sliderThumb),
      brightnessTrack: blend(first.brightnessTrack, second.brightnessTrack),
      volumeTrack: blend(first.volumeTrack, second.volumeTrack),
      wallpaperEffectTrack: blend(
        first.wallpaperEffectTrack,
        second.wallpaperEffectTrack,
      ),
      gestureArmed: blend(first.gestureArmed, second.gestureArmed),
      gesturePill: blend(first.gesturePill, second.gesturePill),
      launchSurface: blend(first.launchSurface, second.launchSurface),
      fallbackAppIcon: blend(first.fallbackAppIcon, second.fallbackAppIcon),
      performanceGood: blend(first.performanceGood, second.performanceGood),
      performanceWarning: blend(
        first.performanceWarning,
        second.performanceWarning,
      ),
      performanceBad: blend(first.performanceBad, second.performanceBad),
      glyphInactive: blend(first.glyphInactive, second.glyphInactive),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ShellColorScheme &&
            other.brightness == brightness &&
            other.background == background &&
            other.surfaceContainerLow == surfaceContainerLow &&
            other.surfaceContainer == surfaceContainer &&
            other.surfaceContainerHigh == surfaceContainerHigh &&
            other.surfaceContainerHighest == surfaceContainerHighest &&
            other.textPrimary == textPrimary &&
            other.panelText == panelText &&
            other.textSecondary == textSecondary &&
            other.textTertiary == textTertiary &&
            other.panelBackground == panelBackground &&
            other.panelBackgroundBottom == panelBackgroundBottom &&
            other.panelHighlight == panelHighlight &&
            other.tileOff == tileOff &&
            other.tileIcon == tileIcon &&
            other.chip == chip &&
            other.overviewScrim == overviewScrim &&
            other.hairline == hairline &&
            other.hairlineSoft == hairlineSoft &&
            other.hairlineWindow == hairlineWindow &&
            other.windowFrameSurface == windowFrameSurface &&
            other.shadow == shadow &&
            other.shadowSoft == shadowSoft &&
            other.sliderThumb == sliderThumb &&
            other.brightnessTrack == brightnessTrack &&
            other.volumeTrack == volumeTrack &&
            other.wallpaperEffectTrack == wallpaperEffectTrack &&
            other.gestureArmed == gestureArmed &&
            other.gesturePill == gesturePill &&
            other.launchSurface == launchSurface &&
            other.fallbackAppIcon == fallbackAppIcon &&
            other.performanceGood == performanceGood &&
            other.performanceWarning == performanceWarning &&
            other.performanceBad == performanceBad &&
            other.glyphInactive == glyphInactive;
  }

  @override
  int get hashCode => Object.hashAll(<Object>[
    brightness,
    background,
    surfaceContainerLow,
    surfaceContainer,
    surfaceContainerHigh,
    surfaceContainerHighest,
    textPrimary,
    panelText,
    textSecondary,
    textTertiary,
    panelBackground,
    panelBackgroundBottom,
    panelHighlight,
    tileOff,
    tileIcon,
    chip,
    overviewScrim,
    hairline,
    hairlineSoft,
    hairlineWindow,
    windowFrameSurface,
    shadow,
    shadowSoft,
    sliderThumb,
    brightnessTrack,
    volumeTrack,
    wallpaperEffectTrack,
    gestureArmed,
    gesturePill,
    launchSurface,
    fallbackAppIcon,
    performanceGood,
    performanceWarning,
    performanceBad,
    glyphInactive,
  ]);
}
