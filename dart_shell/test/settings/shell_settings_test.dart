import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the complete settings document survives a JSON round trip', () {
    const settings = ShellSettings(
      localization: ShellLocalizationSettings(
        locale: ShellLocalePreference.simplifiedChinese,
        twentyFourHourClock: false,
      ),
      appearance: ShellAppearanceSettings(
        colorSchemePreference: DesktopColorSchemePreference.preferLight,
        accentSource: ShellAccentSource.custom,
        customAccentColor: Color(0xffc062ff),
        fontFamily: 'Noto Sans',
        cornerRadiusScale: 1.35,
        panelOpacity: 0.78,
        transparencyMode: ShellTransparencyMode.glass,
        backdropBlurLevel: ShellBackdropBlurLevel.best,
        backdropBlurOpacityThreshold: 0.18,
        glass: ShellGlassConfiguration(
          appearance: ShellGlassAppearance.light,
          opacity: 0.42,
          windowOpacity: 0.73,
          appPanelOpacity: 0.58,
          blurSigma: 18,
          quality: 1,
          thickness: 26,
          refraction: 0.64,
          dispersion: 0.2,
          saturation: 1.3,
          tintStrength: 0.12,
          brightness: 0.08,
          lightAngle: 210,
          lightIntensity: 0.9,
          edgeStrength: 0.8,
          bevelWidthScale: 1.4,
          refractionDepthScale: 0.75,
          rimWidth: 2.5,
          rimFalloff: 1.2,
          oppositeLightStrength: 0.4,
        ),
        focusedWindowBorderEnabled: false,
        focusedWindowOpacity: 0.96,
        unfocusedWindowOpacity: 0.72,
        cursorSize: 44,
        cursorThemeId: 'imported-theme-sha256',
        allowClientCursorSurfaces: false,
      ),
      layout: ShellLayoutSettings(
        windowLayout: DesktopWindowLayout.dwindle,
        workspacesEnabled: true,
        workspaceCount: 7,
        systemBarSide: SystemBarSide.right,
        systemBarOutputNames: <String>['DP-1', 'HDMI-A-1'],
        systemBarThickness: 46,
        maximizePadding: 18,
        minimizedWindowPlacement: MinimizedWindowPlacement.offscreen,
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
        powerButtonAction: PowerButtonAction.hibernate,
        idleLockEnabled: false,
        idleLockTimeoutSeconds: 13 * 60,
        idleDpmsEnabled: false,
        idleDpmsTimeoutSeconds: 47,
        idleSuspendEnabled: true,
        idleSuspendTimeoutSeconds: 72 * 60,
        suspendMode: SuspendMode.deep,
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

  test('power button action persists and produces a typed patch', () {
    const previous = ShellSettings(
      power: ShellPowerSettings(powerButtonAction: PowerButtonAction.dpms),
    );
    final next = previous.copyWith(
      power: previous.power.copyWith(
        powerButtonAction: PowerButtonAction.powerOff,
      ),
    );

    expect(
      ShellSettings.fromJson(next.toJson()).power.powerButtonAction,
      PowerButtonAction.powerOff,
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'power': <String, Object?>{'powerButtonAction': 'powerOff'},
    });
  });

  test('malformed settings fail safe and bounded values are clamped', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'version': 999,
      'localization': <String, dynamic>{'locale': 'future-locale'},
      'appearance': <String, dynamic>{
        'accentSource': 'future-source',
        'fontFamily': 'invalid\u0000family',
        'windowRadius': 400,
        'panelOpacity': 0.01,
        'cursorSize': 400,
        'cursorThemeId': '\u0000invalid',
        'allowClientCursorSurfaces': 'sometimes',
      },
      'layout': <String, dynamic>{
        'windowLayout': 'future-layout',
        'systemBarSide': 'diagonal',
        'systemBarOutputs': <Object?>[' DP-1 ', 42, ''],
        'systemBarThickness': double.nan,
        'maximizePadding': -20,
        'minimizedWindowPlacement': 'somewhere-else',
        'clipboardTrayExtent': 5000,
      },
      'power': <String, dynamic>{
        'idleLockEnabled': 'sometimes',
        'idleLockTimeoutSeconds': 90000,
        'idleDpmsEnabled': 'sometimes',
        'idleDpmsTimeoutSeconds': 90000,
        'idleSuspendEnabled': 'sometimes',
        'idleSuspendTimeoutSeconds': 2,
      },
    });

    expect(settings.localization.locale, ShellLocalePreference.system);
    expect(settings.appearance.accentSource, ShellAccentSource.custom);
    expect(settings.appearance.fontFamily, isEmpty);
    expect(settings.appearance.cornerRadiusScale, ShellRoundness.maximum);
    expect(settings.appearance.panelOpacity, ShellOpacity.minimumPanel);
    expect(settings.appearance.cursorSize, shellCursorMaximumSize);
    expect(settings.appearance.cursorThemeId, 'bibata_modern_ice');
    expect(settings.appearance.allowClientCursorSurfaces, isTrue);
    expect(settings.layout.windowLayout, DesktopWindowLayout.stacking);
    expect(settings.layout.systemBarSide, isNull);
    expect(settings.layout.systemBarOutputNames, <String>['DP-1']);
    expect(settings.layout.systemBarThickness, 33);
    expect(settings.layout.maximizePadding, 0);
    expect(
      settings.layout.minimizedWindowPlacement,
      MinimizedWindowPlacement.offscreen,
    );
    expect(settings.layout.clipboardTrayExtent, clipboardTrayMaximumExtent);
    expect(settings.power.idleLockEnabled, isTrue);
    expect(settings.power.idleLockTimeoutSeconds, 7200);
    expect(settings.power.idleDpmsEnabled, isTrue);
    expect(settings.power.idleDpmsTimeoutSeconds, 7200);
    expect(settings.power.idleSuspendEnabled, isFalse);
    expect(settings.power.idleSuspendTimeoutSeconds, 7200);
  });

  test('idle timeout ordering is repaired without shortening display off', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'power': <String, dynamic>{
        'idleLockTimeoutSeconds': 5400,
        'idleDpmsTimeoutSeconds': 4800,
        'idleSuspendTimeoutSeconds': 1800,
      },
    });

    expect(settings.power.idleDpmsTimeoutSeconds, 4800);
    expect(settings.power.idleSuspendTimeoutSeconds, 4800);
    expect(settings.power.idleLockTimeoutSeconds, 4800);
  });

  test('idle timeouts go down to half a minute', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'power': <String, dynamic>{
        'idleLockTimeoutSeconds': 10,
        'idleDpmsTimeoutSeconds': 30,
      },
    });

    expect(settings.power.idleDpmsTimeoutSeconds, 30);
    expect(settings.power.idleLockTimeoutSeconds, 30);
  });

  test('phone lock and notification choices survive a round trip', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'lockScreen': <String, dynamic>{'fingerprintUnlock': false},
      'power': <String, dynamic>{'screenOffLockDelaySeconds': 7200},
      'notifications': <String, dynamic>{
        'doNotDisturb': true,
        'lockPreview': 'hidden',
        'wakeScreen': false,
      },
      'sound': <String, dynamic>{'keyboardVibration': false},
    });

    expect(settings.lockScreen.fingerprintUnlock, isFalse);
    expect(
      settings.power.screenOffLockDelaySeconds,
      ShellPowerSettings.maximumScreenOffLockDelaySeconds,
    );
    expect(settings.notifications.doNotDisturb, isTrue);
    expect(settings.notifications.lockPreview, NotificationPreviewMode.hidden);
    expect(settings.notifications.wakeScreen, isFalse);
    expect(settings.sound.keyboardVibration, isFalse);
    expect(ShellSettings.fromJson(settings.toJson()), settings);
  });

  test('legacy panel radius migrates to the global roundness scale', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'appearance': <String, dynamic>{'panelRadius': 42},
    });

    expect(settings.appearance.cornerRadiusScale, 1.5);
    final appearance = settings.toJson()['appearance']! as Map<String, Object>;
    expect(appearance.containsKey('windowRadius'), isFalse);
    expect(appearance.containsKey('panelRadius'), isFalse);
  });

  test('the legacy backdrop toggle migrates to a transparency mode', () {
    final disabled = ShellSettings.fromJson(<String, dynamic>{
      'appearance': <String, dynamic>{'backdropBlurEnabled': false},
    });
    final enabled = ShellSettings.fromJson(<String, dynamic>{
      'appearance': <String, dynamic>{'backdropBlurEnabled': true},
    });

    expect(disabled.appearance.transparencyMode, ShellTransparencyMode.off);
    expect(enabled.appearance.transparencyMode, ShellTransparencyMode.blur);
  });
}
