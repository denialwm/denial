import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the complete settings document survives a JSON round trip', () {
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
        backdropBlurLevel: ShellBackdropBlurLevel.best,
        backdropBlurOpacityThreshold: 0.18,
        focusedWindowOpacity: 0.96,
        unfocusedWindowOpacity: 0.72,
        cursorSize: 44,
        cursorThemeId: 'imported-theme-sha256',
        allowClientCursorSurfaces: false,
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
      animations: ShellAnimationSettings(
        durationScale: 0.75,
        panelTravel: 24,
        animateLockScreen: false,
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

  test('typed settings patches preserve cursor authority changes', () {
    const previous = ShellSettings();
    final next = previous.copyWith(
      appearance: previous.appearance.copyWith(
        cursorSize: 48,
        cursorThemeId: 'imported-theme-sha256',
        allowClientCursorSurfaces: false,
      ),
    );

    expect(next.differenceFrom(previous), <String, Object?>{
      'appearance': <String, Object?>{
        'cursorSize': 48.0,
        'cursorThemeId': 'imported-theme-sha256',
        'allowClientCursorSurfaces': false,
      },
    });
  });

  test('malformed settings fail safe and bounded values are clamped', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'version': 999,
      'localization': <String, dynamic>{'locale': 'future-locale'},
      'appearance': <String, dynamic>{
        'accentSource': 'future-source',
        'windowRadius': 400,
        'panelOpacity': 0.01,
        'cursorSize': 400,
        'cursorThemeId': '\u0000invalid',
        'allowClientCursorSurfaces': 'sometimes',
      },
      'layout': <String, dynamic>{
        'systemBarSide': 'diagonal',
        'systemBarOutputs': <Object?>[' DP-1 ', 42, ''],
        'systemBarThickness': double.nan,
        'maximizePadding': -20,
        'clipboardTrayExtent': 5000,
      },
      'power': <String, dynamic>{
        'idleDpmsEnabled': 'sometimes',
        'idleDpmsTimeoutMinutes': 900,
      },
    });

    expect(settings.localization.locale, ShellLocalePreference.system);
    expect(settings.appearance.accentSource, ShellAccentSource.wallpaper);
    expect(settings.appearance.windowRadius, 48);
    expect(settings.appearance.panelOpacity, 0.35);
    expect(settings.appearance.cursorSize, shellCursorMaximumSize);
    expect(settings.appearance.cursorThemeId, 'bibata_modern_ice');
    expect(settings.appearance.allowClientCursorSurfaces, isTrue);
    expect(settings.layout.systemBarSide, isNull);
    expect(settings.layout.systemBarOutputNames, <String>['DP-1']);
    expect(settings.layout.systemBarThickness, 32);
    expect(settings.layout.maximizePadding, 0);
    expect(settings.layout.clipboardTrayExtent, clipboardTrayMaximumExtent);
    expect(settings.power.idleDpmsEnabled, isTrue);
    expect(settings.power.idleDpmsTimeoutMinutes, 120);
  });
}
