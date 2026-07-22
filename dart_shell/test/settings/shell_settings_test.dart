import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings survive a complete JSON round trip', () {
    const settings = ShellSettings(
      appearance: ShellAppearanceSettings(
        accentSource: ShellAccentSource.custom,
        customAccentColor: Color(0xffc062ff),
        focusedWindowBorderColor: Color(0xffffbe55),
        windowRadius: 23,
        panelRadius: 31,
        panelOpacity: 0.78,
        focusedWindowOpacity: 0.96,
        unfocusedWindowOpacity: 0.72,
      ),
      layout: ShellLayoutSettings(
        systemBarSide: SystemBarSide.right,
        systemBarOutputNames: <String>['DP-1', 'HDMI-A-1'],
        systemBarThickness: 46,
        maximizePadding: 18,
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
      },
      'layout': <String, dynamic>{
        'systemBarSide': 'diagonal',
        'systemBarOutputs': <Object?>[' DP-1 ', 42, ''],
        'systemBarThickness': double.nan,
        'maximizePadding': -20,
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
    });

    expect(settings.appearance.accentSource, ShellAccentSource.wallpaper);
    expect(
      settings.appearance.customAccentColor,
      const ShellSettings().appearance.customAccentColor,
    );
    expect(settings.appearance.windowRadius, 48);
    expect(settings.appearance.panelOpacity, 0.35);
    expect(settings.layout.systemBarSide, isNull);
    expect(settings.layout.systemBarOutputNames, <String>['DP-1']);
    expect(settings.layout.systemBarThickness, 32);
    expect(settings.layout.maximizePadding, 0);
    expect(settings.overlays.launcher.anchor, ShellPopupAnchor.bottomRight);
    expect(settings.overlays.launcher.width, 420);
    expect(settings.overlays.launcher.height, 1200);
    expect(settings.overlays.launcher.margin, 96);
    expect(settings.lockScreen.dimAmount, 0.85);
    expect(settings.lockScreen.blurRadius, 0);
    expect(settings.lockScreen.clockScale, 1);
  });
}
