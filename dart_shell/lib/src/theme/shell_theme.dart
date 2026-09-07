import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'backdrop_blur_level.dart';
import 'glass_configuration.dart';
import 'shell_color_scheme.dart';
import 'shell_text_theme.dart';
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

  factory ShellAccentPalette.from(
    Color source, [
    ShellColorScheme colors = ShellColorScheme.dark,
  ]) {
    return ShellAccentPalette._fromGenerated(
      _accentColorScheme(source, colors),
      colors,
    );
  }

  factory ShellAccentPalette._fromGenerated(
    ColorScheme generated,
    ShellColorScheme colors,
  ) {
    final primary = generated.primary;
    final container = generated.primaryContainer;
    final mutedContainer = _tintedSurface(
      primary,
      colors,
      colors.brightness == Brightness.dark ? 0.22 : 0.12,
    );
    final onContainer = _contrastForeground(container);
    return ShellAccentPalette._(
      primary: primary,
      onPrimary: _contrastForeground(primary),
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

  static ShellAccentPalette lerp(
    ShellAccentPalette first,
    ShellAccentPalette second,
    double t,
  ) {
    Color blend(Color a, Color b) => Color.lerp(a, b, t)!;
    return ShellAccentPalette._(
      primary: blend(first.primary, second.primary),
      onPrimary: blend(first.onPrimary, second.onPrimary),
      container: blend(first.container, second.container),
      onContainer: blend(first.onContainer, second.onContainer),
      onContainerSecondary: blend(
        first.onContainerSecondary,
        second.onContainerSecondary,
      ),
      mutedContainer: blend(first.mutedContainer, second.mutedContainer),
      onMutedContainer: blend(first.onMutedContainer, second.onMutedContainer),
      subtle: blend(first.subtle, second.subtle),
      outline: blend(first.outline, second.outline),
      selection: blend(first.selection, second.selection),
    );
  }
}

@immutable
class ShellThemeData {
  const ShellThemeData({
    this.colors = ShellColorScheme.dark,
    Color accent = ShellBrandColors.defaultAccent,
    this.cornerRadiusScale = ShellRoundness.normal,
    this.panelOpacity = ShellOpacity.panel,
    this.cardOpacity = ShellOpacity.card,
    this.transparencyMode = ShellTransparencyMode.blur,
    this.backdropBlurLevel = ShellBackdropBlurLevel.fast,
    this.backdropBlurOpacityThreshold = 0.2,
    this.glass = const ShellGlassConfiguration(),
    this.focusedWindowBorderEnabled = true,
    this.focusedWindowOpacity = 1,
    this.unfocusedWindowOpacity = 1,
    this._resolvedTextTheme,
    this._resolvedAccentPalette,
    this._resolvedGeneratedColorScheme,
  }) : accentSeed = accent;

  final ShellColorScheme colors;
  final Color accentSeed;
  final ShellTextTheme? _resolvedTextTheme;
  final ShellAccentPalette? _resolvedAccentPalette;
  final ColorScheme? _resolvedGeneratedColorScheme;
  final double cornerRadiusScale;
  final double panelOpacity;
  final double cardOpacity;
  final ShellTransparencyMode transparencyMode;
  final ShellBackdropBlurLevel backdropBlurLevel;
  final double backdropBlurOpacityThreshold;
  final ShellGlassConfiguration glass;
  final bool focusedWindowBorderEnabled;
  final double focusedWindowOpacity;
  final double unfocusedWindowOpacity;

  static final Expando<_ShellThemeResolution> _resolutionCache =
      Expando<_ShellThemeResolution>('ShellThemeData resolution');

  _ShellThemeResolution get _resolution =>
      _resolutionCache[this] ??= _ShellThemeResolution(this);

  double get backdropBlurSigma => backdropBlurLevel.sigma;

  double get backdropBlurDownsampleScale => backdropBlurLevel.downsampleScale;

  bool get backdropBlurEnabled => transparencyMode != ShellTransparencyMode.off;

  /// Resolves the selected backdrop material while retaining immutable filter
  /// configurations across surfaces with identical geometry.
  ImageFilterConfig backdropFilterConfigAt(
    double strength, {
    BorderRadius borderRadius = BorderRadius.zero,
    bool useWindowAlphaThreshold = false,
    bool singleWindowSurface = false,
  }) => _resolution.backdropFilterConfigAt(
    strength,
    borderRadius: borderRadius,
    useWindowAlphaThreshold: useWindowAlphaThreshold,
    singleWindowSurface: singleWindowSurface,
  );

  Brightness get brightness => colors.brightness;

  /// Semantic text roles resolved once for this immutable theme value.
  ShellTextTheme get text => _resolution.text;

  /// Seed-derived accent roles resolved once for this immutable theme value.
  ShellAccentPalette get accentPalette => _resolution.accentPalette;

  /// The normalized primary role. [accentSeed] is the persisted source color.
  Color get accent => accentPalette.primary;

  /// Scales a component's base radius by the single user-selected roundness.
  double scaledRadius(double radius) => radius * cornerRadiusScale;

  Radius radius(double baseRadius) => _resolution.radius(baseRadius);

  BorderRadius borderRadius(double baseRadius) =>
      _resolution.borderRadius(baseRadius);

  double get windowRadius => scaledRadius(ShellRadii.window);

  double get notificationRadius => scaledRadius(ShellRadii.notification);

  double get tileRadius => scaledRadius(ShellRadii.tile);

  double get tileWideRadius => scaledRadius(ShellRadii.tileWide);

  double get panelRadius => scaledRadius(ShellRadii.panel);

  double get chipRadius => scaledRadius(ShellRadii.chip);

  double get roundButtonRadius => scaledRadius(ShellRadii.roundButton);

  /// The normalized backing opacity shared by panels, notifications, and HUDs.
  double get effectivePanelOpacity =>
      panelOpacity.clamp(ShellOpacity.minimumPanel, 1.0).toDouble();

  double get effectiveCardOpacity =>
      cardOpacity.clamp(ShellOpacity.minimumCard, 1.0).toDouble();

  Color panelColor(Color color) => _resolution.panelColor(color);

  LinearGradient panelGradient(Color top, Color bottom) =>
      _resolution.panelGradient(top, bottom);

  Color cardColor(Color color) => _resolution.cardColor(color);

  LinearGradient cardGradient(Color top, Color bottom) =>
      _resolution.cardGradient(top, bottom);

  /// Material compatibility theme resolved once for this immutable value.
  ThemeData toMaterialTheme() => _resolution.materialTheme;

  ShellThemeData copyWith({
    ShellColorScheme? colors,
    Color? accent,
    double? cornerRadiusScale,
    double? panelOpacity,
    double? cardOpacity,
    ShellTransparencyMode? transparencyMode,
    ShellBackdropBlurLevel? backdropBlurLevel,
    double? backdropBlurOpacityThreshold,
    ShellGlassConfiguration? glass,
    bool? focusedWindowBorderEnabled,
    double? focusedWindowOpacity,
    double? unfocusedWindowOpacity,
  }) {
    return ShellThemeData(
      colors: colors ?? this.colors,
      accent: accent ?? accentSeed,
      cornerRadiusScale: cornerRadiusScale ?? this.cornerRadiusScale,
      panelOpacity: panelOpacity ?? this.panelOpacity,
      cardOpacity: cardOpacity ?? this.cardOpacity,
      transparencyMode: transparencyMode ?? this.transparencyMode,
      backdropBlurLevel: backdropBlurLevel ?? this.backdropBlurLevel,
      backdropBlurOpacityThreshold:
          backdropBlurOpacityThreshold ?? this.backdropBlurOpacityThreshold,
      glass: glass ?? this.glass,
      focusedWindowBorderEnabled:
          focusedWindowBorderEnabled ?? this.focusedWindowBorderEnabled,
      focusedWindowOpacity: focusedWindowOpacity ?? this.focusedWindowOpacity,
      unfocusedWindowOpacity:
          unfocusedWindowOpacity ?? this.unfocusedWindowOpacity,
    );
  }

  static ShellThemeData lerp(
    ShellThemeData first,
    ShellThemeData second,
    double t,
  ) {
    if (t <= 0) {
      return first;
    }
    if (t >= 1) {
      return second;
    }
    final colorsMatch = first.colors == second.colors;
    final accentsMatch = first.accentSeed == second.accentSeed;
    final colorInputsMatch = colorsMatch && accentsMatch;
    double blend(double a, double b) => a + (b - a) * t;
    return ShellThemeData(
      colors: colorsMatch
          ? first.colors
          : ShellColorScheme.lerp(first.colors, second.colors, t),
      accent: accentsMatch
          ? first.accentSeed
          : Color.lerp(first.accentSeed, second.accentSeed, t)!,
      resolvedTextTheme: colorsMatch
          ? first.text
          : ShellTextTheme.lerp(first.text, second.text, t),
      resolvedAccentPalette: colorInputsMatch
          ? first.accentPalette
          : ShellAccentPalette.lerp(
              first.accentPalette,
              second.accentPalette,
              t,
            ),
      resolvedGeneratedColorScheme: colorInputsMatch
          ? first._resolution.generatedColorScheme
          : ColorScheme.lerp(
              first._resolution.generatedColorScheme,
              second._resolution.generatedColorScheme,
              t,
            ),
      cornerRadiusScale: blend(
        first.cornerRadiusScale,
        second.cornerRadiusScale,
      ),
      panelOpacity: blend(first.panelOpacity, second.panelOpacity),
      cardOpacity: blend(first.cardOpacity, second.cardOpacity),
      transparencyMode: t < 0.5
          ? first.transparencyMode
          : second.transparencyMode,
      backdropBlurLevel: t < 0.5
          ? first.backdropBlurLevel
          : second.backdropBlurLevel,
      backdropBlurOpacityThreshold: blend(
        first.backdropBlurOpacityThreshold,
        second.backdropBlurOpacityThreshold,
      ),
      glass: ShellGlassConfiguration.lerp(first.glass, second.glass, t),
      focusedWindowBorderEnabled: t < 0.5
          ? first.focusedWindowBorderEnabled
          : second.focusedWindowBorderEnabled,
      focusedWindowOpacity: blend(
        first.focusedWindowOpacity,
        second.focusedWindowOpacity,
      ),
      unfocusedWindowOpacity: blend(
        first.unfocusedWindowOpacity,
        second.unfocusedWindowOpacity,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellThemeData &&
        other.colors == colors &&
        other.accentSeed == accentSeed &&
        other.cornerRadiusScale == cornerRadiusScale &&
        other.panelOpacity == panelOpacity &&
        other.cardOpacity == cardOpacity &&
        other.transparencyMode == transparencyMode &&
        other.backdropBlurLevel == backdropBlurLevel &&
        other.backdropBlurOpacityThreshold == backdropBlurOpacityThreshold &&
        other.glass == glass &&
        other.focusedWindowBorderEnabled == focusedWindowBorderEnabled &&
        other.focusedWindowOpacity == focusedWindowOpacity &&
        other.unfocusedWindowOpacity == unfocusedWindowOpacity;
  }

  @override
  int get hashCode => Object.hash(
    colors,
    accentSeed,
    cornerRadiusScale,
    panelOpacity,
    cardOpacity,
    transparencyMode,
    backdropBlurLevel,
    backdropBlurOpacityThreshold,
    glass,
    focusedWindowBorderEnabled,
    focusedWindowOpacity,
    unfocusedWindowOpacity,
  );
}

/// Lazily memoizes derived objects by [ShellThemeData] identity.
///
/// Keeping the cache outside the immutable value preserves const construction.
/// Interpolated animation values also benefit: every widget in one transition
/// frame shares the same derived text and accent objects, while an accent-only
/// shell frame never pays to construct a complete Material [ThemeData].
class _ShellThemeResolution {
  _ShellThemeResolution(this.theme);

  final ShellThemeData theme;
  final Map<double, Radius> _radii = <double, Radius>{};
  final Map<double, BorderRadius> _borderRadii = <double, BorderRadius>{};
  final Map<Color, Color> _panelColors = <Color, Color>{};
  final Map<Color, Color> _cardColors = <Color, Color>{};
  final Map<({Color top, Color bottom}), LinearGradient> _panelGradients =
      <({Color top, Color bottom}), LinearGradient>{};
  final Map<({Color top, Color bottom}), LinearGradient> _cardGradients =
      <({Color top, Color bottom}), LinearGradient>{};

  Radius radius(double baseRadius) => _radii.putIfAbsent(
    baseRadius,
    () => Radius.circular(theme.scaledRadius(baseRadius)),
  );

  BorderRadius borderRadius(double baseRadius) => _borderRadii.putIfAbsent(
    baseRadius,
    () => BorderRadius.circular(theme.scaledRadius(baseRadius)),
  );

  Color panelColor(Color color) => _panelColors.putIfAbsent(
    color,
    () => color.withValues(alpha: theme.effectivePanelOpacity),
  );

  LinearGradient panelGradient(Color top, Color bottom) =>
      _panelGradients.putIfAbsent(
        (top: top, bottom: bottom),
        () => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[panelColor(top), panelColor(bottom)],
        ),
      );

  Color cardColor(Color color) => _cardColors.putIfAbsent(
    color,
    () => color.withValues(alpha: theme.effectiveCardOpacity),
  );

  LinearGradient cardGradient(Color top, Color bottom) =>
      _cardGradients.putIfAbsent(
        (top: top, bottom: bottom),
        () => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[cardColor(top), cardColor(bottom)],
        ),
      );

  late final ShellTextTheme text =
      theme._resolvedTextTheme ?? ShellTextTheme.from(theme.colors);

  late final ColorScheme generatedColorScheme =
      theme._resolvedGeneratedColorScheme ??
      _accentColorScheme(theme.accentSeed, theme.colors);

  late final ShellAccentPalette accentPalette =
      theme._resolvedAccentPalette ??
      ShellAccentPalette._fromGenerated(generatedColorScheme, theme.colors);

  static const int _materialStrengthSteps = 32;
  final Map<
    ({
      int strength,
      BorderRadius borderRadius,
      bool windowThreshold,
      bool singleWindowSurface,
    }),
    ImageFilterConfig
  >
  _backdropFilters = {};

  ImageFilterConfig backdropFilterConfigAt(
    double strength, {
    required BorderRadius borderRadius,
    required bool useWindowAlphaThreshold,
    required bool singleWindowSurface,
  }) {
    final step = (strength.clamp(0.0, 1.0) * _materialStrengthSteps)
        .round()
        .clamp(1, _materialStrengthSteps)
        .toInt();
    final key = (
      strength: step,
      borderRadius: borderRadius,
      windowThreshold: useWindowAlphaThreshold,
      singleWindowSurface: singleWindowSurface,
    );
    return _backdropFilters.putIfAbsent(key, () {
      final materialStrength = step / _materialStrengthSteps;
      final threshold = useWindowAlphaThreshold
          ? theme.backdropBlurOpacityThreshold.clamp(0.0, 1.0).toDouble()
          : null;
      if (theme.transparencyMode == ShellTransparencyMode.glass) {
        final glass = theme.glass;
        return ImageFilterConfig.glass(
          sigmaX: glass.blurSigma * materialStrength,
          sigmaY: glass.blurSigma * materialStrength,
          topLeft: borderRadius.topLeft,
          topRight: borderRadius.topRight,
          bottomRight: borderRadius.bottomRight,
          bottomLeft: borderRadius.bottomLeft,
          downsampleScale: glass.quality,
          thickness: glass.thickness,
          refraction: glass.refraction * materialStrength,
          dispersion: glass.dispersion,
          saturation: 1 + (glass.saturation - 1) * materialStrength,
          tint: accentPalette.primary,
          tintStrength: glass.tintStrength * materialStrength,
          brightness: glass.brightness * materialStrength,
          lightAngle: glass.lightAngle * math.pi / 180,
          lightIntensity: glass.lightIntensity * materialStrength,
          edgeStrength: glass.edgeStrength * materialStrength,
          backdropAlphaThreshold: threshold,
          backdropAlphaThresholdIsSingleSurface: singleWindowSurface,
        );
      }
      return ImageFilterConfig.blur(
        sigmaX: theme.backdropBlurSigma * materialStrength,
        sigmaY: theme.backdropBlurSigma * materialStrength,
        tileMode: ui.TileMode.clamp,
        downsampleScale: theme.backdropBlurDownsampleScale,
        backdropAlphaThreshold: threshold,
        backdropAlphaThresholdIsSingleSurface: singleWindowSurface,
      );
    });
  }

  late final ThemeData materialTheme = ThemeData(
    brightness: theme.brightness,
    useMaterial3: true,
    scaffoldBackgroundColor: ShellMediaColors.transparentDark,
    colorScheme: generatedColorScheme.copyWith(
      surface: theme.colors.background,
      onSurface: theme.colors.textPrimary,
      onSurfaceVariant: theme.colors.textSecondary,
      outline: theme.colors.hairline,
      outlineVariant: theme.colors.hairlineSoft,
      surfaceContainerLow: theme.colors.surfaceContainerLow,
      surfaceContainer: theme.colors.surfaceContainer,
      surfaceContainerHigh: theme.colors.surfaceContainerHigh,
      surfaceContainerHighest: theme.colors.surfaceContainerHighest,
      shadow: theme.colors.shadow,
    ),
    cardTheme: CardThemeData(
      color: cardColor(theme.colors.surfaceContainerLow),
      shape: RoundedRectangleBorder(
        borderRadius: theme.borderRadius(ShellRadii.tile),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: theme.borderRadius(ShellRadii.panel),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: theme.borderRadius(ShellRadii.chip),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: OutlineInputBorder(
        borderRadius: theme.borderRadius(ShellRadii.chip),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: theme.borderRadius(ShellRadii.chip),
          ),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: theme.borderRadius(ShellRadii.chip),
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: theme.borderRadius(ShellRadii.chip),
          ),
        ),
      ),
    ),
  );
}

class ShellTheme extends InheritedWidget {
  const ShellTheme({required this.data, required super.child, super.key});

  final ShellThemeData data;

  static ShellThemeData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ShellTheme>()?.data ??
        const ShellThemeData();
  }

  static ShellColorScheme colorsOf(BuildContext context) => of(context).colors;

  @override
  bool updateShouldNotify(covariant ShellTheme oldWidget) {
    return oldWidget.data != data;
  }
}

class AnimatedShellTheme extends ImplicitlyAnimatedWidget {
  const AnimatedShellTheme({
    required this.data,
    required this.child,
    required super.duration,
    super.curve = Curves.easeInOut,
    super.key,
  });

  final ShellThemeData data;
  final Widget child;

  @override
  AnimatedWidgetBaseState<AnimatedShellTheme> createState() =>
      _AnimatedShellThemeState();
}

/// Installs the interpolated semantic base style below [AnimatedShellTheme].
class ShellDefaultTextStyle extends StatelessWidget {
  const ShellDefaultTextStyle({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(style: context.shellTheme.text.base, child: child);
  }
}

class _AnimatedShellThemeState
    extends AnimatedWidgetBaseState<AnimatedShellTheme> {
  _ShellThemeDataTween? _theme;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _theme =
        visitor(
              _theme,
              widget.data,
              (dynamic value) =>
                  _ShellThemeDataTween(begin: value as ShellThemeData),
            )
            as _ShellThemeDataTween?;
  }

  @override
  Widget build(BuildContext context) {
    return ShellTheme(data: _theme!.evaluate(animation), child: widget.child);
  }
}

class _ShellThemeDataTween extends Tween<ShellThemeData> {
  _ShellThemeDataTween({super.begin});

  @override
  ShellThemeData lerp(double t) => ShellThemeData.lerp(begin!, end!, t);
}

extension ShellThemeBuildContext on BuildContext {
  ShellThemeData get shellTheme => ShellTheme.of(this);

  ShellColorScheme get shellColors => ShellTheme.colorsOf(this);
}

Color _tintedSurface(Color accent, ShellColorScheme colors, double amount) {
  return Color.alphaBlend(
    accent.withValues(alpha: amount),
    colors.surfaceContainerHigh.withValues(alpha: 1),
  );
}

ColorScheme _accentColorScheme(Color source, ShellColorScheme colors) {
  final primary = source.withValues(alpha: 1);
  return ColorScheme.fromSeed(
    seedColor: primary,
    brightness: colors.brightness,
    surface: colors.background,
  ).copyWith(primary: primary, onPrimary: _contrastForeground(primary));
}

Color _contrastForeground(Color background) {
  const dark = ShellMediaColors.darkness;
  const light = ShellMediaColors.contrastLight;
  final backgroundLuminance = background.computeLuminance();
  const darkLuminance = 0.0;
  const lightLuminance = 1.0;
  final darkContrast = _contrastRatio(backgroundLuminance, darkLuminance);
  final lightContrast = _contrastRatio(backgroundLuminance, lightLuminance);
  return darkContrast >= lightContrast ? dark : light;
}

double _contrastRatio(double first, double second) {
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}
