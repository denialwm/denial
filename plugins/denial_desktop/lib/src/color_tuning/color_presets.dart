import 'dart:ui' show Offset;

import 'package:denial_flutter_sdk/localization.dart';

import 'color_grade.dart';

/// A look that ships with Denial. A puck at hue h (red at the top,
/// clockwise) pushed a of the way out sits at (sin h, -cos h) * a.
enum ColorPreset {
  warm(
    ColorGrade(
      sliders: {
        GradeSlider.temperature: 0.35,
        GradeSlider.tint: 0.04,
        GradeSlider.vibrance: 0.1,
      },
      // Orange highlights.
      wheels: {GradeWheel.gain: WheelPosition(Offset(0.07, -0.12), 0.04)},
    ),
  ),
  cool(
    ColorGrade(
      sliders: {
        GradeSlider.temperature: -0.35,
        GradeSlider.tint: -0.03,
        GradeSlider.contrast: 0.1,
      },
      // Cyan midtones.
      wheels: {GradeWheel.gamma: WheelPosition(Offset(-0.03, 0.12), 0)},
    ),
  ),
  logix(
    ColorGrade(
      sliders: {
        GradeSlider.exposure: -0.22,
        GradeSlider.contrast: 0.21,
        GradeSlider.saturation: 0.19,
        GradeSlider.vibrance: 0.16,
        GradeSlider.temperature: -0.34,
      },
      wheels: {
        GradeWheel.lift: WheelPosition(Offset(-0.102, -0.085), -0.24),
        GradeWheel.gamma: WheelPosition(Offset(0.103, 0.09), -0.02),
        GradeWheel.gain: WheelPosition(Offset(0.096, -0.111), 0.03),
      },
    ),
  ),
  matte(
    ColorGrade(
      sliders: {GradeSlider.contrast: -0.3, GradeSlider.saturation: -0.15},
      wheels: {
        // Lifted blacks, softer whites.
        GradeWheel.lift: WheelPosition(Offset.zero, 0.5),
        GradeWheel.gain: WheelPosition(Offset.zero, -0.08),
      },
    ),
  ),
  film(
    ColorGrade(
      sliders: {
        GradeSlider.contrast: 0.2,
        GradeSlider.saturation: -0.1,
        GradeSlider.vibrance: 0.15,
      },
      wheels: {
        // Teal shadows, orange highlights.
        GradeWheel.lift: WheelPosition(Offset(-0.1, 0.4), 0.05),
        GradeWheel.gain: WheelPosition(Offset(0.12, -0.2), 0),
      },
    ),
  ),
  night(
    ColorGrade(
      sliders: {
        GradeSlider.exposure: -0.6,
        GradeSlider.contrast: 0.15,
        GradeSlider.saturation: -0.35,
        GradeSlider.temperature: -0.4,
      },
      // Blue shadows.
      wheels: {GradeWheel.lift: WheelPosition(Offset(-0.26, 0.15), 0)},
    ),
  ),
  mono(
    ColorGrade(
      sliders: {GradeSlider.contrast: 0.25, GradeSlider.saturation: -1},
    ),
  );

  const ColorPreset(this.grade);

  final ColorGrade grade;

  String label(AppLocalizations l10n) => switch (this) {
    warm => l10n.colorPresetWarm,
    cool => l10n.colorPresetCool,
    logix => l10n.colorPresetLogix,
    matte => l10n.colorPresetMatte,
    film => l10n.colorPresetFilm,
    night => l10n.colorPresetNight,
    mono => l10n.colorPresetMono,
  };
}
