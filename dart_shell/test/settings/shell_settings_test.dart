import 'dart:ui' show Brightness;

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

  test('color-scheme preferences have explicit shell and portal semantics', () {
    expect(
      const ShellSettings().appearance.colorSchemePreference,
      DesktopColorSchemePreference.preferDark,
    );
    expect(
      DesktopColorSchemePreference.preferDark.effectiveBrightness,
      Brightness.dark,
    );
    expect(DesktopColorSchemePreference.preferDark.portalValue, 1);
    expect(
      DesktopColorSchemePreference.preferLight.effectiveBrightness,
      Brightness.light,
    );
    expect(DesktopColorSchemePreference.preferLight.portalValue, 2);
    expect(
      DesktopColorSchemePreference.noPreference.effectiveBrightness,
      denialDefaultBrightness,
    );
    expect(DesktopColorSchemePreference.noPreference.portalValue, 0);
  });

  test('every color-scheme preference survives JSON serialization', () {
    for (final preference in DesktopColorSchemePreference.values) {
      final settings = ShellSettings(
        appearance: ShellAppearanceSettings(colorSchemePreference: preference),
      );
      expect(
        ShellSettings.fromJson(
          settings.toJson(),
        ).appearance.colorSchemePreference,
        preference,
      );
    }
  });

  test('schema 9 appearance migrates to explicit dark preference', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'version': 9,
      'appearance': <String, dynamic>{},
    });

    expect(
      settings.appearance.colorSchemePreference,
      DesktopColorSchemePreference.preferDark,
    );
    expect(
      (settings.toJson()['appearance']
          as Map<String, Object>)['colorSchemePreference'],
      'preferDark',
    );
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
        colorSchemePreference: DesktopColorSchemePreference.preferLight,
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
          hoverTriggerEnabled: false,
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
      applicationEnvironment: ShellApplicationEnvironmentSettings(
        variables: <String, String?>{
          'DISPLAY': null,
          'MOZ_ENABLE_WAYLAND': '1',
        },
        applications: <String, Map<String, String?>>{
          'org.mozilla.firefox.desktop': <String, String?>{
            'MOZ_ENABLE_WAYLAND': '0',
          },
        },
      ),
    );

    expect(ShellSettings.fromJson(settings.toJson()), settings);
    expect(settings.toJson()['version'], ShellSettings.schemaVersion);
  });

  test(
    'per-placement hover trigger defaults on and rejects malformed JSON',
    () {
      expect(const ShellOverlaySettings().launcher.hoverTriggerEnabled, isTrue);
      expect(
        ShellSettings.fromJson(<String, dynamic>{
          'overlays': <String, dynamic>{
            'launcher': <String, dynamic>{'hoverTriggerEnabled': 'sometimes'},
          },
        }).overlays.launcher.hoverTriggerEnabled,
        isTrue,
      );
    },
  );

  test('legacy global hover preference migrates to both triggers', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'overlays': <String, dynamic>{'hoverTriggersEnabled': false},
    });

    expect(settings.overlays.launcher.hoverTriggerEnabled, isFalse);
    expect(settings.overlays.dashboard.hoverTriggerEnabled, isFalse);
  });

  test('per-placement hover trigger is included in typed differences', () {
    const previous = ShellSettings();
    const next = ShellSettings(
      overlays: ShellOverlaySettings(
        launcher: ShellPopupPlacement(
          anchor: ShellPopupAnchor.topLeft,
          width: 680,
          height: 620,
          margin: 14,
          hoverTriggerEnabled: false,
        ),
      ),
    );

    expect(next.differenceFrom(previous), <String, Object?>{
      'overlays': <String, Object?>{
        'launcher': <String, Object>{
          'anchor': 'topLeft',
          'width': 680.0,
          'height': 620.0,
          'margin': 14.0,
          'hoverTriggerEnabled': false,
        },
      },
    });
  });

  test('typed differences contain only changed settings fields', () {
    const previous = ShellSettings(
      appearance: ShellAppearanceSettings(windowRadius: 12),
      layout: ShellLayoutSettings(systemBarSide: SystemBarSide.top),
    );
    final next = previous.copyWith(
      appearance: previous.appearance.copyWith(
        windowRadius: 24,
        backdropBlurLevel: ShellBackdropBlurLevel.best,
      ),
      layout: previous.layout.copyWith(clearSystemBarSide: true),
    );

    expect(next.differenceFrom(previous), <String, Object?>{
      'appearance': <String, Object?>{
        'windowRadius': 24.0,
        'backdropBlurLevel': 'best',
        'backdropBlurSigma': 14.0,
      },
      'layout': <String, Object?>{'systemBarSide': null},
    });
  });

  test('application environment differences replace the complete map', () {
    const previous = ShellSettings(
      applicationEnvironment: ShellApplicationEnvironmentSettings(
        variables: <String, String?>{'A': 'old', 'REMOVE_ME': null},
      ),
    );
    final next = previous.copyWith(
      applicationEnvironment: previous.applicationEnvironment
          .withoutOverride('A')
          .withOverride('EMPTY', ''),
    );

    expect(next.differenceFrom(previous), <String, Object?>{
      'applicationEnvironment': <String, Object?>{
        'default': <String, Object?>{'REMOVE_ME': null, 'EMPTY': ''},
        'applications': <String, Object?>{},
      },
    });
    expect(
      ShellSettings.fromJson(next.toJson()).applicationEnvironment,
      next.applicationEnvironment,
    );
  });

  test('application environment parsing discards invalid entries', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'applicationEnvironment': <String, dynamic>{
        'default': <String, dynamic>{
          'VALID': 'yes',
          '_REMOVE': null,
          '9INVALID': 'no',
          'ALSO_INVALID': 12,
        },
        'applications': <String, dynamic>{
          'org.example.App.desktop': <String, dynamic>{'APP_ONLY': '1'},
          'not/a.desktop': <String, dynamic>{'IGNORED': '1'},
        },
      },
    });

    expect(settings.applicationEnvironment.variables, <String, String?>{
      'VALID': 'yes',
      '_REMOVE': null,
    });
    expect(
      settings.applicationEnvironment.applications,
      <String, Map<String, String?>>{
        'org.example.App.desktop': <String, String?>{'APP_ONLY': '1'},
      },
    );
  });

  test('per-application overrides are isolated and restore inheritance', () {
    final settings =
        const ShellApplicationEnvironmentSettings(
          variables: <String, String?>{'MODE': 'global'},
        ).withOverride(
          'MODE',
          'application',
          desktopFileId: 'org.example.App.desktop',
        );

    expect(settings.variables, <String, String?>{'MODE': 'global'});
    expect(settings.variablesFor('org.example.App.desktop'), <String, String?>{
      'MODE': 'application',
    });
    expect(
      settings
          .withoutOverride('MODE', desktopFileId: 'org.example.App.desktop')
          .applications,
      isEmpty,
    );
  });

  test('malformed and out-of-range values are safe and clamped', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'version': 999,
      'localization': <String, dynamic>{'locale': 'future-locale'},
      'appearance': <String, dynamic>{
        'accentSource': 'future-source',
        'customAccentColor': -1,
        'windowRadius': 400,
        'panelRadius': -4,
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
    expect(settings.appearance.panelRadius, 0);
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

  test('application popup height accepts 200 pixels and clamps below it', () {
    ShellSettings settingsWithHeight(double height) =>
        ShellSettings.fromJson(<String, dynamic>{
          'overlays': <String, dynamic>{
            'launcher': <String, dynamic>{'height': height},
          },
        });

    expect(launcherOverlayMinimumHeight, 200);
    expect(settingsWithHeight(200).overlays.launcher.height, 200);
    expect(settingsWithHeight(199).overlays.launcher.height, 200);
    expect(settingsWithHeight(240).overlays.launcher.height, 240);
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
