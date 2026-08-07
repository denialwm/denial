import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fresh shell surfaces use the shared 75% opacity', () {
    expect(const ShellSettings().appearance.panelOpacity, 0.75);
  });

  test('settings survive a complete JSON round trip', () {
    const settings = ShellSettings(
      appearance: ShellAppearanceSettings(
        accentSource: ShellAccentSource.custom,
        customAccentColor: Color(0xffc062ff),
        windowRadius: 23,
        panelRadius: 31,
        panelOpacity: 0.78,
        backdropBlurEnabled: false,
        backdropBlurSigma: 27,
        backdropBlurOpacityThreshold: 0.18,
        focusedWindowOpacity: 0.96,
        unfocusedWindowOpacity: 0.72,
      ),
      layout: ShellLayoutSettings(
        systemBarSide: SystemBarSide.right,
        systemBarOutputNames: <String>['DP-1', 'HDMI-A-1'],
        systemBarThickness: 46,
        maximizePadding: 18,
        clipboardTrayEdge: ClipboardTrayEdge.bottom,
        clipboardTrayExtent: 512,
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
      'appearance': <String, dynamic>{
        'accentSource': 'future-source',
        'customAccentColor': -1,
        'windowRadius': 400,
        'panelOpacity': 0.01,
        'backdropBlurEnabled': 'sometimes',
        'backdropBlurSigma': 400,
        'backdropBlurOpacityThreshold': 4,
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

    expect(settings.appearance.accentSource, ShellAccentSource.wallpaper);
    expect(
      settings.appearance.customAccentColor,
      const ShellSettings().appearance.customAccentColor,
    );
    expect(settings.appearance.windowRadius, 48);
    expect(settings.appearance.panelOpacity, 0.35);
    expect(settings.appearance.backdropBlurEnabled, isTrue);
    expect(settings.appearance.backdropBlurSigma, 32);
    expect(settings.appearance.backdropBlurOpacityThreshold, 1);
    expect(settings.layout.systemBarSide, isNull);
    expect(settings.layout.systemBarOutputNames, <String>['DP-1']);
    expect(settings.layout.systemBarThickness, 32);
    expect(settings.layout.maximizePadding, 0);
    expect(settings.layout.clipboardTrayEdge, ClipboardTrayEdge.right);
    expect(settings.layout.clipboardTrayExtent, 720);
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
    expect(settings.appearance.backdropBlurSigma, 18);
  });
}
