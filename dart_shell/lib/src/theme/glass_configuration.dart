import 'package:flutter/foundation.dart';

enum ShellTransparencyMode { off, blur, glass }

enum ShellGlassAppearance { dark, light }

@immutable
class ShellGlassConfiguration {
  const ShellGlassConfiguration({
    this.appearance = ShellGlassAppearance.dark,
    this.opacity = 0.17,
    this.blurSigma = 14,
    this.quality = 0.75,
    this.thickness = 20,
    this.refraction = 0.55,
    this.dispersion = 0.12,
    this.saturation = 1.2,
    this.tintStrength = 0.08,
    this.brightness = 0.06,
    this.lightAngle = 225,
    this.lightIntensity = 0.7,
    this.edgeStrength = 0.65,
    this.bevelWidthScale = 1,
    this.refractionDepthScale = 1,
    this.rimWidth = 1.5,
    this.rimFalloff = 0.89,
    this.oppositeLightStrength = 0.8,
  });

  static const double minimumBlurSigma = 0;
  static const double maximumBlurSigma = 30;
  static const double minimumQuality = 0.25;
  static const double maximumQuality = 1;
  static const double minimumThickness = 4;
  static const double maximumThickness = 48;
  static const double minimumRefraction = 0;
  static const double maximumRefraction = 1;
  static const double minimumDispersion = 0;
  static const double maximumDispersion = 1;
  static const double minimumSaturation = 0.5;
  static const double maximumSaturation = 2;
  static const double minimumTintStrength = 0;
  static const double maximumTintStrength = 0.4;
  static const double minimumBrightness = -0.2;
  static const double maximumBrightness = 0.2;
  static const double minimumLightAngle = 0;
  static const double maximumLightAngle = 360;
  static const double minimumLightIntensity = 0;
  static const double maximumLightIntensity = 1.5;
  static const double minimumEdgeStrength = 0;
  static const double maximumEdgeStrength = 1.5;

  static const double minimumBevelWidthScale = 0.25;
  static const double maximumBevelWidthScale = 3;
  static const double minimumRefractionDepthScale = 0.25;
  static const double maximumRefractionDepthScale = 3;
  static const double minimumRimWidth = 0.5;
  static const double maximumRimWidth = 6;
  static const double minimumRimFalloff = 0.1;
  static const double maximumRimFalloff = 3;
  static const double minimumOppositeLightStrength = 0;
  static const double maximumOppositeLightStrength = 1.5;

  final ShellGlassAppearance appearance;

  /// Backing opacity shared by every translucent shell surface in glass mode.
  final double opacity;
  final double blurSigma;
  final double quality;
  final double thickness;
  final double refraction;
  final double dispersion;
  final double saturation;
  final double tintStrength;
  final double brightness;
  final double lightAngle;
  final double lightIntensity;
  final double edgeStrength;
  final double bevelWidthScale;
  final double refractionDepthScale;
  final double rimWidth;
  final double rimFalloff;
  final double oppositeLightStrength;

  ShellGlassConfiguration copyWith({
    ShellGlassAppearance? appearance,
    double? opacity,
    double? blurSigma,
    double? quality,
    double? thickness,
    double? refraction,
    double? dispersion,
    double? saturation,
    double? tintStrength,
    double? brightness,
    double? lightAngle,
    double? lightIntensity,
    double? edgeStrength,
    double? bevelWidthScale,
    double? refractionDepthScale,
    double? rimWidth,
    double? rimFalloff,
    double? oppositeLightStrength,
  }) {
    return ShellGlassConfiguration(
      appearance: appearance ?? this.appearance,
      opacity: opacity ?? this.opacity,
      blurSigma: blurSigma ?? this.blurSigma,
      quality: quality ?? this.quality,
      thickness: thickness ?? this.thickness,
      refraction: refraction ?? this.refraction,
      dispersion: dispersion ?? this.dispersion,
      saturation: saturation ?? this.saturation,
      tintStrength: tintStrength ?? this.tintStrength,
      brightness: brightness ?? this.brightness,
      lightAngle: lightAngle ?? this.lightAngle,
      lightIntensity: lightIntensity ?? this.lightIntensity,
      edgeStrength: edgeStrength ?? this.edgeStrength,
      bevelWidthScale: bevelWidthScale ?? this.bevelWidthScale,
      refractionDepthScale: refractionDepthScale ?? this.refractionDepthScale,
      rimWidth: rimWidth ?? this.rimWidth,
      rimFalloff: rimFalloff ?? this.rimFalloff,
      oppositeLightStrength:
          oppositeLightStrength ?? this.oppositeLightStrength,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'appearance': appearance.name,
    'opacity': opacity,
    'blurSigma': blurSigma,
    'quality': quality,
    'thickness': thickness,
    'refraction': refraction,
    'dispersion': dispersion,
    'saturation': saturation,
    'tintStrength': tintStrength,
    'brightness': brightness,
    'lightAngle': lightAngle,
    'lightIntensity': lightIntensity,
    'edgeStrength': edgeStrength,
    'bevelWidthScale': bevelWidthScale,
    'refractionDepthScale': refractionDepthScale,
    'rimWidth': rimWidth,
    'rimFalloff': rimFalloff,
    'oppositeLightStrength': oppositeLightStrength,
  };

  factory ShellGlassConfiguration.fromJson(
    Object? value, [
    ShellGlassConfiguration defaults = const ShellGlassConfiguration(),
  ]) {
    final json = value is Map<String, dynamic>
        ? value
        : const <String, dynamic>{};
    double number(String key, double fallback, double minimum, double maximum) {
      final candidate = json[key];
      if (candidate is! num || !candidate.isFinite) {
        return fallback;
      }
      return candidate.toDouble().clamp(minimum, maximum).toDouble();
    }

    return ShellGlassConfiguration(
      appearance: ShellGlassAppearance.values.firstWhere(
        (appearance) => appearance.name == json['appearance'],
        orElse: () => defaults.appearance,
      ),
      opacity: number('opacity', defaults.opacity, 0, 1),
      blurSigma: number(
        'blurSigma',
        defaults.blurSigma,
        minimumBlurSigma,
        maximumBlurSigma,
      ),
      quality: number(
        'quality',
        defaults.quality,
        minimumQuality,
        maximumQuality,
      ),
      thickness: number(
        'thickness',
        defaults.thickness,
        minimumThickness,
        maximumThickness,
      ),
      refraction: number(
        'refraction',
        defaults.refraction,
        minimumRefraction,
        maximumRefraction,
      ),
      dispersion: number(
        'dispersion',
        defaults.dispersion,
        minimumDispersion,
        maximumDispersion,
      ),
      saturation: number(
        'saturation',
        defaults.saturation,
        minimumSaturation,
        maximumSaturation,
      ),
      tintStrength: number(
        'tintStrength',
        defaults.tintStrength,
        minimumTintStrength,
        maximumTintStrength,
      ),
      brightness: number(
        'brightness',
        defaults.brightness,
        minimumBrightness,
        maximumBrightness,
      ),
      lightAngle: number(
        'lightAngle',
        defaults.lightAngle,
        minimumLightAngle,
        maximumLightAngle,
      ),
      lightIntensity: number(
        'lightIntensity',
        defaults.lightIntensity,
        minimumLightIntensity,
        maximumLightIntensity,
      ),
      edgeStrength: number(
        'edgeStrength',
        defaults.edgeStrength,
        minimumEdgeStrength,
        maximumEdgeStrength,
      ),
      bevelWidthScale: number(
        'bevelWidthScale',
        defaults.bevelWidthScale,
        minimumBevelWidthScale,
        maximumBevelWidthScale,
      ),
      refractionDepthScale: number(
        'refractionDepthScale',
        defaults.refractionDepthScale,
        minimumRefractionDepthScale,
        maximumRefractionDepthScale,
      ),
      rimWidth: number(
        'rimWidth',
        defaults.rimWidth,
        minimumRimWidth,
        maximumRimWidth,
      ),
      rimFalloff: number(
        'rimFalloff',
        defaults.rimFalloff,
        minimumRimFalloff,
        maximumRimFalloff,
      ),
      oppositeLightStrength: number(
        'oppositeLightStrength',
        defaults.oppositeLightStrength,
        minimumOppositeLightStrength,
        maximumOppositeLightStrength,
      ),
    );
  }

  static ShellGlassConfiguration lerp(
    ShellGlassConfiguration first,
    ShellGlassConfiguration second,
    double t,
  ) {
    double blend(double a, double b) => a + (b - a) * t;
    return ShellGlassConfiguration(
      appearance: t < 0.5 ? first.appearance : second.appearance,
      opacity: blend(first.opacity, second.opacity),
      blurSigma: blend(first.blurSigma, second.blurSigma),
      quality: blend(first.quality, second.quality),
      thickness: blend(first.thickness, second.thickness),
      refraction: blend(first.refraction, second.refraction),
      dispersion: blend(first.dispersion, second.dispersion),
      saturation: blend(first.saturation, second.saturation),
      tintStrength: blend(first.tintStrength, second.tintStrength),
      brightness: blend(first.brightness, second.brightness),
      lightAngle: blend(first.lightAngle, second.lightAngle),
      lightIntensity: blend(first.lightIntensity, second.lightIntensity),
      edgeStrength: blend(first.edgeStrength, second.edgeStrength),
      bevelWidthScale: blend(first.bevelWidthScale, second.bevelWidthScale),
      refractionDepthScale: blend(
        first.refractionDepthScale,
        second.refractionDepthScale,
      ),
      rimWidth: blend(first.rimWidth, second.rimWidth),
      rimFalloff: blend(first.rimFalloff, second.rimFalloff),
      oppositeLightStrength: blend(
        first.oppositeLightStrength,
        second.oppositeLightStrength,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ShellGlassConfiguration &&
        other.appearance == appearance &&
        other.opacity == opacity &&
        other.blurSigma == blurSigma &&
        other.quality == quality &&
        other.thickness == thickness &&
        other.refraction == refraction &&
        other.dispersion == dispersion &&
        other.saturation == saturation &&
        other.tintStrength == tintStrength &&
        other.brightness == brightness &&
        other.lightAngle == lightAngle &&
        other.lightIntensity == lightIntensity &&
        other.edgeStrength == edgeStrength &&
        other.bevelWidthScale == bevelWidthScale &&
        other.refractionDepthScale == refractionDepthScale &&
        other.rimWidth == rimWidth &&
        other.rimFalloff == rimFalloff &&
        other.oppositeLightStrength == oppositeLightStrength;
  }

  @override
  int get hashCode => Object.hash(
    appearance,
    opacity,
    blurSigma,
    quality,
    thickness,
    refraction,
    dispersion,
    saturation,
    tintStrength,
    brightness,
    lightAngle,
    lightIntensity,
    edgeStrength,
    bevelWidthScale,
    refractionDepthScale,
    rimWidth,
    rimFalloff,
    oppositeLightStrength,
  );
}
