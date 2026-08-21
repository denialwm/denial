import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/services/upower_service.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_battery_section.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_power_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows UPower metrics and applies the supported end threshold', (
    tester,
  ) async {
    final backend = _UPowerBackend();
    await _pumpPowerPage(tester, backend);
    await tester.pump();

    expect(find.text('Battery information'), findsOneWidget);
    expect(find.text('AS3GXAE C536-49'), findsOneWidget);
    expect(find.text('Fully charged'), findsOneWidget);
    expect(find.text('Health'), findsOneWidget);
    expect(find.text('78%'), findsOneWidget);
    expect(find.text('Charge cycles'), findsOneWidget);
    expect(find.text('213'), findsOneWidget);
    expect(find.text('44.6 / 57.0 Wh'), findsOneWidget);
    expect(find.text('Charge limit'), findsOneWidget);
    expect(find.text('Stop · 80%'), findsOneWidget);
    expect(find.textContaining('read-only in UPower'), findsOneWidget);

    final toggleFinder = find.byKey(
      settingsBatteryChargeLimitKey(_battery.objectPath),
    );
    expect(tester.widget<SettingsToggle>(toggleFinder).value, isFalse);

    await tester.ensureVisible(toggleFinder);
    await tester.tap(toggleFinder);
    await tester.pump();
    await tester.pump();

    expect(backend.thresholdCalls, <bool>[true]);
    expect(tester.widget<SettingsToggle>(toggleFinder).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('battery layout supports the minimum width and large text', (
    tester,
  ) async {
    await _pumpPowerPage(
      tester,
      _UPowerBackend(),
      size: const Size(520, 1000),
      textScaler: const TextScaler.linear(1.6),
    );
    await tester.pump();

    expect(find.text('Battery information'), findsOneWidget);
    expect(find.text('Charge limit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPowerPage(
  WidgetTester tester,
  UPowerBackend backend, {
  Size size = const Size(900, 1000),
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [upowerServiceProvider.overrideWithValue(backend)],
      child: DenialLocalizationScope(
        locale: const Locale('en'),
        child: MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: Material(
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => SizedBox(
                    width: size.width,
                    height: size.height,
                    child: SettingsPowerPage(
                      settings: const ShellPowerSettings(),
                      onEnabledChanged: (_) {},
                      onTimeoutChanged: (_) {},
                      onReset: () {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _UPowerBackend implements UPowerBackend {
  final thresholdCalls = <bool>[];

  @override
  Future<UPowerSnapshot> readSnapshot() async => UPowerSnapshot(
    daemonVersion: '1.91.3',
    onBattery: false,
    batteries: <UPowerBattery>[_battery],
  );

  @override
  Future<void> setChargeThresholdEnabled(
    String objectPath,
    bool enabled,
  ) async {
    expect(objectPath, _battery.objectPath);
    thresholdCalls.add(enabled);
  }

  @override
  Future<void> dispose() async {}
}

const _battery = UPowerBattery(
  objectPath: '/org/freedesktop/UPower/devices/battery_BAT0',
  nativePath: 'BAT0',
  vendor: 'AS3GXAE',
  model: 'C536-49',
  serial: '0F5A',
  state: UPowerBatteryState.fullyCharged,
  technology: UPowerBatteryTechnology.lithiumIon,
  warningLevel: UPowerWarningLevel.none,
  percentage: 100,
  healthPercentage: 78.2292,
  energy: 44.6094,
  energyFull: 44.6094,
  energyFullDesign: 57.024,
  energyRate: 0,
  voltage: 12.73,
  temperature: 0,
  timeToEmpty: null,
  timeToFull: null,
  chargeCycles: 213,
  chargeThresholdSupported: true,
  chargeThresholdEnabled: false,
  chargeThresholdSettings: UPowerBattery.chargeEndSetting,
  chargeStartThreshold: 75,
  chargeEndThreshold: 80,
);
