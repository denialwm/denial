import 'package:denial_dart_shell/src/services/upower_service.dart';
import 'package:denial_dart_shell/src/state/upower.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads UPower and applies the charge threshold optimistically',
    () async {
      final backend = _UPowerBackend();
      final container = ProviderContainer(
        overrides: [upowerServiceProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen<UPowerState>(
        upowerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await pumpEventQueue();

      final loaded = container.read(upowerProvider);
      expect(loaded.loading, isFalse);
      expect(loaded.snapshot?.daemonVersion, '1.91.3');
      expect(loaded.snapshot?.batteries.single.chargeThresholdEnabled, isFalse);

      await container
          .read(upowerProvider.notifier)
          .setChargeThresholdEnabled(loaded.snapshot!.batteries.single, true);

      expect(backend.thresholdCalls, <bool>[true]);
      expect(
        container
            .read(upowerProvider)
            .snapshot
            ?.batteries
            .single
            .chargeThresholdEnabled,
        isTrue,
      );
      expect(container.read(upowerProvider).changingThresholds, isEmpty);
    },
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
