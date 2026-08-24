import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fresh shell surfaces use the shared 75% opacity', () {
    expect(const ShellSettings().appearance.panelOpacity, 0.75);
  });

  test('blur levels use the requested quality and radius mappings', () {
    expect(ShellBackdropBlurLevel.shitty.sigma, 6);
    expect(ShellBackdropBlurLevel.shitty.downsampleScale, 0.25);
    expect(ShellBackdropBlurLevel.fast.sigma, 6);
    expect(ShellBackdropBlurLevel.fast.downsampleScale, 0.5);
    expect(ShellBackdropBlurLevel.good.sigma, 6);
    expect(ShellBackdropBlurLevel.good.downsampleScale, 1);
    expect(ShellBackdropBlurLevel.best.sigma, 14);
    expect(ShellBackdropBlurLevel.best.downsampleScale, 1);
  });

  test('settings survive a complete JSON round trip', () {
    const settings = ShellSettings(
      localization: ShellLocalizationSettings(
        locale: ShellLocalePreference.simplifiedChinese,
      ),
      appearance: ShellAppearanceSettings(
        accentSource: ShellAccentSource.custom,
        customAccentColor: Color(0xffc062ff),
        windowRadius: 23,
        panelRadius: 31,
        panelOpacity: 0.78,
        backdropBlurEnabled: false,
        backdropBlurLevel: ShellBackdropBlurLevel.fast,
        backdropBlurOpacityThreshold: 0.18,
        focusedWindowOpacity: 0.96,
        unfocusedWindowOpacity: 0.72,
        cursorSize: 44,
      ),
      layout: ShellLayoutSettings(
        systemBarSide: SystemBarSide.right,
        systemBarOutputNames: <String>['DP-1', 'HDMI-A-1'],
        systemBarThickness: 46,
        maximizePadding: 18,
        clipboardTrayEdge: ClipboardTrayEdge.bottom,
        clipboardTrayExtent: 288,
      ),
      overlays: ShellOverlaySettings(
        launcher: ShellPopupPlacement(
          anchor: ShellPopupAnchor.topRight,
          width: 720,
          height: 650,
          margin: 20,
        ),
      ),
      lockScreen: ShellLockScreenSettings(
        dimAmount: 0.42,
        blurRadius: 14,
        clockScale: 1.15,
        showSystemStatus: false,
      ),
      power: ShellPowerSettings(
        idleDpmsEnabled: false,
        idleDpmsTimeoutMinutes: 47,
      ),
    );

    expect(ShellSettings.fromJson(settings.toJson()), settings);
    expect(settings.toJson()['version'], ShellSettings.schemaVersion);
  });

  test('malformed and out-of-range values are safe and clamped', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'version': 999,
      'localization': <String, dynamic>{'locale': 'future-locale'},
      'appearance': <String, dynamic>{
        'accentSource': 'future-source',
        'customAccentColor': -1,
        'windowRadius': 400,
        'panelOpacity': 0.01,
        'backdropBlurEnabled': 'sometimes',
        'backdropBlurSigma': 400,
        'backdropBlurOpacityThreshold': 4,
        'cursorSize': 400,
      },
      'layout': <String, dynamic>{
        'systemBarSide': 'diagonal',
        'systemBarOutputs': <Object?>[' DP-1 ', 42, ''],
        'systemBarThickness': double.nan,
        'maximizePadding': -20,
        'clipboardTrayEdge': 'diagonal',
        'clipboardTrayExtent': 5000,
      },
      'overlays': <String, dynamic>{
        'launcher': <String, dynamic>{
          'anchor': 'bottomRight',
          'width': 10,
          'height': 5000,
          'margin': 500,
        },
      },
      'lockScreen': <String, dynamic>{
        'dimAmount': 8,
        'blurRadius': -4,
        'clockScale': 'large',
      },
      'power': <String, dynamic>{
        'idleDpmsEnabled': 'sometimes',
        'idleDpmsTimeoutMinutes': 900,
      },
    });

    expect(settings.localization.locale, ShellLocalePreference.system);
    expect(settings.appearance.accentSource, ShellAccentSource.wallpaper);
    expect(
      settings.appearance.customAccentColor,
      const ShellSettings().appearance.customAccentColor,
    );
    expect(settings.appearance.windowRadius, 48);
    expect(settings.appearance.panelOpacity, 0.35);
    expect(settings.appearance.backdropBlurEnabled, isTrue);
    expect(settings.appearance.backdropBlurLevel, ShellBackdropBlurLevel.fast);
    expect(settings.appearance.backdropBlurOpacityThreshold, 1);
    expect(settings.appearance.cursorSize, shellCursorMaximumSize);
    expect(settings.layout.systemBarSide, isNull);
    expect(settings.layout.systemBarOutputNames, <String>['DP-1']);
    expect(settings.layout.systemBarThickness, 32);
    expect(settings.layout.maximizePadding, 0);
    expect(settings.layout.clipboardTrayEdge, ClipboardTrayEdge.right);
    expect(settings.layout.clipboardTrayExtent, clipboardTrayMaximumExtent);
    expect(settings.overlays.launcher.anchor, ShellPopupAnchor.bottomRight);
    expect(settings.overlays.launcher.width, 420);
    expect(settings.overlays.launcher.height, 1200);
    expect(settings.overlays.launcher.margin, 96);
    expect(settings.lockScreen.dimAmount, 0.85);
    expect(settings.lockScreen.blurRadius, 0);
    expect(settings.lockScreen.clockScale, 1);
    expect(settings.power.idleDpmsEnabled, isTrue);
    expect(settings.power.idleDpmsTimeoutMinutes, 120);
  });

  test('older settings inherit the optimized blur defaults', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'version': 3,
      'appearance': <String, dynamic>{},
    });

    expect(settings.appearance.backdropBlurEnabled, isTrue);
    expect(settings.appearance.backdropBlurLevel, ShellBackdropBlurLevel.fast);
    expect(settings.appearance.cursorSize, shellCursorDefaultSize);
  });

  test('legacy blur radii migrate to the fast default', () {
    final lowRadius = ShellSettings.fromJson(<String, dynamic>{
      'appearance': <String, dynamic>{'backdropBlurSigma': 6},
    });
    final highRadius = ShellSettings.fromJson(<String, dynamic>{
      'appearance': <String, dynamic>{'backdropBlurSigma': 18},
    });

    expect(lowRadius.appearance.backdropBlurLevel, ShellBackdropBlurLevel.fast);
    expect(
      highRadius.appearance.backdropBlurLevel,
      ShellBackdropBlurLevel.fast,
    );
    expect(
      (lowRadius.toJson()['appearance']
          as Map<String, Object>)['backdropBlurSigma'],
      6,
    );
  });

  test('locale preferences expose only explicit language overrides', () {
    expect(const ShellLocalizationSettings().localeOverride, isNull);
    expect(
      const ShellLocalizationSettings(
        locale: ShellLocalePreference.english,
      ).localeOverride?.toLanguageTag(),
      'en',
    );
    expect(
      const ShellLocalizationSettings(
        locale: ShellLocalePreference.simplifiedChinese,
      ).localeOverride?.toLanguageTag(),
      'zh',
    );
  });
}
