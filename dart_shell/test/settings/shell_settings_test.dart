import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/power_button_action.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/models/suspend_mode.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:denial_dart_shell/src/theme/glass_configuration.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new installations use the saved appearance and portable layout', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{});
    expect(settings, const ShellSettings());
    expect(settings.appearance.transparencyMode, ShellTransparencyMode.glass);
    expect(settings.appearance.cornerRadiusScale, 0.3);
    expect(settings.appearance.panelOpacity, 0.75);
    expect(settings.appearance.cardOpacity, 0.4421052631578947);
    expect(settings.appearance.backdropBlurLevel, ShellBackdropBlurLevel.good);
    expect(settings.appearance.backdropBlurOpacityThreshold, 0.65);
    expect(settings.appearance.glass.blurSigma, 17);
    expect(settings.appearance.glass.thickness, 28);
    expect(settings.layout.systemBarSide, SystemBarSide.top);
    expect(settings.layout.systemBarOutputNames, isEmpty);
    expect(settings.layout.systemBarThickness, 33);
    expect(settings.layout.maximizePadding, 8);
    expect(settings.layout.scrollingLayoutWheelSpeed, 1);
    expect(
      settings.layout.scrollingLayoutWheelUpDirection,
      ScrollingLayoutWheelUpDirection.left,
    );
    expect(
      settings.layout.minimizedWindowPlacement,
      MinimizedWindowPlacement.offscreen,
    );
    expect(settings.layout.clipboardTrayEdge, ClipboardTrayEdge.left);
    expect(settings.layout.clipboardTrayExtent, 160);
  });

  test(
    'saved appearance and automatic panel placement survive new defaults',
    () {
      const existing = ShellSettings(
        appearance: ShellAppearanceSettings(
          transparencyMode: ShellTransparencyMode.blur,
          cornerRadiusScale: 1,
          panelOpacity: 0.9,
          glass: ShellGlassConfiguration(thickness: 20, blurSigma: 14),
        ),
        layout: ShellLayoutSettings(
          systemBarSide: null,
          systemBarOutputNames: ['DP-4'],
          systemBarThickness: 32,
          maximizePadding: 10,
          minimizedWindowPlacement: MinimizedWindowPlacement.desktop,
          clipboardTrayEdge: ClipboardTrayEdge.right,
          clipboardTrayExtent: 250,
        ),
      );
      expect(ShellSettings.fromJson(existing.toJson()), existing);
    },
  );

  test(
    'idle policy defaults lock and display off on while suspend stays off',
    () {
      const power = ShellPowerSettings();

      expect(power.idleLockEnabled, isTrue);
      expect(power.idleLockTimeoutMinutes, 5);
      expect(power.idleDpmsEnabled, isTrue);
      expect(power.idleDpmsTimeoutMinutes, 10);
      expect(power.idleSuspendEnabled, isFalse);
      expect(power.idleSuspendTimeoutMinutes, 30);
      expect(power.suspendMode, SuspendMode.systemDefault);
      expect(power.powerButtonAction, PowerButtonAction.dpms);
    },
  );

  test('the complete settings document survives a JSON round trip', () {
    const settings = ShellSettings(
      localization: ShellLocalizationSettings(
        locale: ShellLocalePreference.simplifiedChinese,
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
        idleLockTimeoutMinutes: 13,
        idleDpmsEnabled: false,
        idleDpmsTimeoutMinutes: 47,
        idleSuspendEnabled: true,
        idleSuspendTimeoutMinutes: 72,
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

  test('suspend mode persists and produces a typed patch', () {
    const previous = ShellSettings();
    final next = previous.copyWith(
      power: previous.power.copyWith(suspendMode: SuspendMode.s2idle),
    );

    expect(
      ShellSettings.fromJson(next.toJson()).power.suspendMode,
      SuspendMode.s2idle,
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'power': <String, Object?>{'suspendMode': 's2idle'},
    });
  });

  test('power button action persists and produces a typed patch', () {
    const previous = ShellSettings();
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

  test('window layout persists and produces a typed patch', () {
    const previous = ShellSettings();
    final next = previous.copyWith(
      layout: previous.layout.copyWith(
        windowLayout: DesktopWindowLayout.dwindle,
      ),
    );

    expect(
      ShellSettings.fromJson(next.toJson()).layout.windowLayout,
      DesktopWindowLayout.dwindle,
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'layout': <String, Object?>{'windowLayout': 'dwindle'},
    });

    final scrolling = next.copyWith(
      layout: next.layout.copyWith(windowLayout: DesktopWindowLayout.scrolling),
    );
    expect(
      ShellSettings.fromJson(scrolling.toJson()).layout.windowLayout,
      DesktopWindowLayout.scrolling,
    );
    expect(scrolling.differenceFrom(next), <String, Object?>{
      'layout': <String, Object?>{'windowLayout': 'scrolling'},
    });
  });

  test('workspace settings persist and produce a typed patch', () {
    const previous = ShellSettings();
    final next = previous.copyWith(
      layout: previous.layout.copyWith(
        workspacesEnabled: true,
        workspaceCount: 6,
        workspaceSwitchingOrientation: WorkspaceSwitchingOrientation.vertical,
      ),
    );

    final restored = ShellSettings.fromJson(next.toJson());
    expect(restored.layout.workspacesEnabled, isTrue);
    expect(restored.layout.workspaceCount, 6);
    expect(
      restored.layout.workspaceSwitchingOrientation,
      WorkspaceSwitchingOrientation.vertical,
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'layout': <String, Object?>{
        'workspacesEnabled': true,
        'workspaceCount': 6,
        'workspaceSwitchingOrientation': 'vertical',
      },
    });
  });

  test('scrolling layout wheel settings persist and produce a typed patch', () {
    const previous = ShellSettings();
    final next = previous.copyWith(
      layout: previous.layout.copyWith(
        scrollingLayoutWheelSpeed: 2.25,
        scrollingLayoutWheelUpDirection: ScrollingLayoutWheelUpDirection.right,
      ),
    );

    final restored = ShellSettings.fromJson(next.toJson());
    expect(restored.layout.scrollingLayoutWheelSpeed, 2.25);
    expect(
      restored.layout.scrollingLayoutWheelUpDirection,
      ScrollingLayoutWheelUpDirection.right,
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'layout': <String, Object?>{
        'scrollingLayoutWheelSpeed': 2.25,
        'scrollingLayoutWheelUpDirection': 'right',
      },
    });

    final bounded = ShellSettings.fromJson(<String, Object?>{
      'layout': <String, Object?>{
        'scrollingLayoutWheelSpeed': 4.001,
        'scrollingLayoutWheelUpDirection': 'future',
      },
    });
    expect(bounded.layout.scrollingLayoutWheelSpeed, 4);
    expect(
      bounded.layout.scrollingLayoutWheelUpDirection,
      ScrollingLayoutWheelUpDirection.left,
    );
  });

  test('minimized window placement persists and produces a typed patch', () {
    const previous = ShellSettings(
      layout: ShellLayoutSettings(
        minimizedWindowPlacement: MinimizedWindowPlacement.desktop,
      ),
    );
    final next = previous.copyWith(
      layout: previous.layout.copyWith(
        minimizedWindowPlacement: MinimizedWindowPlacement.offscreen,
      ),
    );

    expect(
      ShellSettings.fromJson(next.toJson()).layout.minimizedWindowPlacement,
      MinimizedWindowPlacement.offscreen,
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'layout': <String, Object?>{'minimizedWindowPlacement': 'offscreen'},
    });
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

  test('shell font family persists and produces a typed patch', () {
    const previous = ShellSettings();
    final next = previous.copyWith(
      appearance: previous.appearance.copyWith(fontFamily: 'Noto Sans'),
    );

    expect(
      ShellSettings.fromJson(next.toJson()).appearance.fontFamily,
      'Noto Sans',
    );
    expect(next.differenceFrom(previous), <String, Object?>{
      'appearance': <String, Object?>{'fontFamily': 'Noto Sans'},
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
        'idleLockTimeoutMinutes': 900,
        'idleDpmsEnabled': 'sometimes',
        'idleDpmsTimeoutMinutes': 900,
        'idleSuspendEnabled': 'sometimes',
        'idleSuspendTimeoutMinutes': 2,
      },
    });

    expect(settings.localization.locale, ShellLocalePreference.system);
    expect(settings.appearance.accentSource, ShellAccentSource.wallpaper);
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
    expect(settings.power.idleLockTimeoutMinutes, 120);
    expect(settings.power.idleDpmsEnabled, isTrue);
    expect(settings.power.idleDpmsTimeoutMinutes, 120);
    expect(settings.power.idleSuspendEnabled, isFalse);
    expect(settings.power.idleSuspendTimeoutMinutes, 120);
  });

  test('idle timeout ordering is repaired without shortening display off', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'power': <String, dynamic>{
        'idleLockTimeoutMinutes': 90,
        'idleDpmsTimeoutMinutes': 80,
        'idleSuspendTimeoutMinutes': 30,
      },
    });

    expect(settings.power.idleDpmsTimeoutMinutes, 80);
    expect(settings.power.idleSuspendTimeoutMinutes, 80);
    expect(settings.power.idleLockTimeoutMinutes, 80);
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

  test('older settings preserve the original glass tuning defaults', () {
    final glass = ShellGlassConfiguration.fromJson(<String, dynamic>{
      'thickness': 20,
    });
    expect(glass.bevelWidthScale, 1);
    expect(glass.refractionDepthScale, 1);
    expect(glass.rimWidth, 1.5);
    expect(glass.rimFalloff, 0.89);
    expect(glass.oppositeLightStrength, 0.8);
    expect(glass, const ShellGlassConfiguration(thickness: 20));
  });

  test('glass appearance and opacity tolerate older and invalid settings', () {
    for (final value in [
      null,
      <String, dynamic>{},
      <String, dynamic>{'appearance': 'invalid', 'opacity': double.nan},
    ]) {
      final glass = ShellGlassConfiguration.fromJson(value);
      expect(glass.appearance, ShellGlassAppearance.dark);
      expect(glass.opacity, const ShellGlassConfiguration().opacity);
    }
    expect(
      ShellGlassConfiguration.fromJson(<String, dynamic>{
        'opacity': -1,
      }).opacity,
      0,
    );
    expect(
      ShellGlassConfiguration.fromJson(<String, dynamic>{'opacity': 2}).opacity,
      1,
    );
    const configured = ShellGlassConfiguration(
      appearance: ShellGlassAppearance.light,
      opacity: 0.42,
    );
    expect(ShellGlassConfiguration.fromJson(configured.toJson()), configured);
  });

  test('glass tuning validates persisted values independently', () {
    final glass = ShellGlassConfiguration.fromJson(<String, dynamic>{
      'bevelWidthScale': 0,
      'refractionDepthScale': double.nan,
      'rimWidth': 99,
      'rimFalloff': 'bad',
      'oppositeLightStrength': -1,
    });
    expect(glass.bevelWidthScale, 0.25);
    expect(glass.refractionDepthScale, 1);
    expect(glass.rimWidth, 6);
    expect(glass.rimFalloff, 0.89);
    expect(glass.oppositeLightStrength, 0);
  });

  test('glass settings reject malformed values and clamp optical limits', () {
    final settings = ShellSettings.fromJson(<String, dynamic>{
      'appearance': <String, dynamic>{
        'transparencyMode': 'glass',
        'glass': <String, dynamic>{
          'blurSigma': -10,
          'quality': 9,
          'thickness': 200,
          'refraction': double.nan,
          'dispersion': -2,
          'saturation': 12,
          'tintStrength': 4,
          'brightness': -3,
          'lightAngle': 900,
          'lightIntensity': -1,
          'edgeStrength': 8,
        },
      },
    });

    expect(settings.appearance.transparencyMode, ShellTransparencyMode.glass);
    expect(settings.appearance.glass.blurSigma, 0);
    expect(settings.appearance.glass.quality, 1);
    expect(settings.appearance.glass.thickness, 48);
    expect(settings.appearance.glass.refraction, 0.56);
    expect(settings.appearance.glass.dispersion, 0);
    expect(settings.appearance.glass.saturation, 2);
    expect(settings.appearance.glass.tintStrength, 0.4);
    expect(settings.appearance.glass.brightness, -0.2);
    expect(settings.appearance.glass.lightAngle, 360);
    expect(settings.appearance.glass.lightIntensity, 0);
    expect(settings.appearance.glass.edgeStrength, 1.5);
  });
}
