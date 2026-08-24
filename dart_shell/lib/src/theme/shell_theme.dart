import 'package:flutter/widgets.dart';

import 'backdrop_blur_level.dart';
import 'tokens.dart';

@immutable
class ShellAccentPalette {
  const ShellAccentPalette._({
    required this.primary,
    required this.onPrimary,
    required this.container,
    required this.onContainer,
    required this.onContainerSecondary,
    required this.mutedContainer,
    required this.onMutedContainer,
    required this.subtle,
    required this.outline,
    required this.selection,
  });

  factory ShellAccentPalette.from(Color source) {
    final primary = source.withValues(alpha: 1);
    final container = _tintedSurface(primary, 0.38);
    final mutedContainer = _tintedSurface(primary, 0.22);
    final onContainer = _contrastForeground(container);
    return ShellAccentPalette._(
      primary: primary,
      onPrimary: _accentForeground(primary),
      container: container,
      onContainer: onContainer,
      onContainerSecondary: onContainer.withValues(alpha: 0.78),
      mutedContainer: mutedContainer,
      onMutedContainer: _contrastForeground(mutedContainer),
      subtle: primary.withValues(alpha: 0.10),
      outline: primary.withValues(alpha: 0.34),
      selection: primary.withValues(alpha: 0.38),
    );
  }

  final Color primary;
  final Color onPrimary;
  final Color container;
  final Color onContainer;
  final Color onContainerSecondary;
  final Color mutedContainer;
  final Color onMutedContainer;
  final Color subtle;
  final Color outline;
  final Color selection;
}

@immutable
class ShellThemeData {
  const ShellThemeData({
    this.accent = ShellColors.accent,
    this.windowRadius = ShellRadii.window,
    this.panelRadius = ShellRadii.panel,
    this.panelOpacity = ShellOpacity.panel,
    this.backdropBlurEnabled = true,
    this.backdropBlurLevel = ShellBackdropBlurLevel.fast,
    this.backdropBlurOpacityThreshold = 0.05,
    this.focusedWindowOpacity = 1,
    this.unfocusedWindowOpacity = 1,
  });

  final Color accent;
  final double windowRadius;
  final double panelRadius;
  final double panelOpacity;
  final bool backdropBlurEnabled;
  final ShellBackdropBlurLevel backdropBlurLevel;
  final double backdropBlurOpacityThreshold;
  final double focusedWindowOpacity;
  final double unfocusedWindowOpacity;

  double get backdropBlurSigma => backdropBlurLevel.sigma;

  double get backdropBlurDownsampleScale => backdropBlurLevel.downsampleScale;

  ShellAccentPalette get accentPalette => ShellAccentPalette.from(accent);

  Color panelColor(Color color) => color.withValues(alpha: panelOpacity);

  @override
  bool operator ==(Object other) {
    return other is ShellThemeData &&
        other.accent == accent &&
        other.windowRadius == windowRadius &&
        other.panelRadius == panelRadius &&
        other.panelOpacity == panelOpacity &&
        other.backdropBlurEnabled == backdropBlurEnabled &&
        other.backdropBlurLevel == backdropBlurLevel &&
        other.backdropBlurOpacityThreshold == backdropBlurOpacityThreshold &&
        other.focusedWindowOpacity == focusedWindowOpacity &&
        other.unfocusedWindowOpacity == unfocusedWindowOpacity;
  }

  @override
  int get hashCode => Object.hash(
    accent,
    windowRadius,
    panelRadius,
    panelOpacity,
    backdropBlurEnabled,
    backdropBlurLevel,
    backdropBlurOpacityThreshold,
    focusedWindowOpacity,
    unfocusedWindowOpacity,
  );
}

class ShellTheme extends InheritedWidget {
  const ShellTheme({required this.data, required super.child, super.key});

  final ShellThemeData data;

  static ShellThemeData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ShellTheme>()?.data ??
        const ShellThemeData();
  }

  @override
  bool updateShouldNotify(covariant ShellTheme oldWidget) {
    return oldWidget.data != data;
  }
}

Color _tintedSurface(Color accent, double amount) {
  return Color.alphaBlend(
    accent.withValues(alpha: amount),
    ShellColors.surfaceContainerHigh.withValues(alpha: 1),
  );
}

Color _accentForeground(Color background) {
  const dark = Color(0xff000000);
  const light = Color(0xffffffff);
  final perceivedBrightness =
      background.r * 0.299 + background.g * 0.587 + background.b * 0.114;
  return perceivedBrightness > 0.5 ? dark : light;
}

Color _contrastForeground(Color background) {
  const dark = Color(0xff000000);
  const light = Color(0xffffffff);
  final backgroundLuminance = background.computeLuminance();
  final darkContrast = _contrastRatio(
    backgroundLuminance,
    dark.computeLuminance(),
  );
  final lightContrast = _contrastRatio(
    backgroundLuminance,
    light.computeLuminance(),
  );
  return darkContrast >= lightContrast ? dark : light;
}

double _contrastRatio(double first, double second) {
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}
