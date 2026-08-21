import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/upower_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'parses the system battery and every supported threshold capability',
    () {
      final battery = parseUPowerSystemBattery(
        '/org/freedesktop/UPower/devices/battery_BAT0',
        <String, DBusValue>{
          'Type': const DBusUint32(2),
          'IsPresent': const DBusBoolean(true),
          'NativePath': const DBusString('BAT0'),
          'Vendor': const DBusString('AS3GXAE'),
          'Model': const DBusString('C536-49'),
          'Serial': const DBusString('0F5A'),
          'State': const DBusUint32(4),
          'Technology': const DBusUint32(1),
          'WarningLevel': const DBusUint32(1),
          'Percentage': const DBusDouble(100),
          'Capacity': const DBusDouble(78.2292),
          'Energy': const DBusDouble(44.6094),
          'EnergyFull': const DBusDouble(44.6094),
          'EnergyFullDesign': const DBusDouble(57.024),
          'EnergyRate': const DBusDouble(0),
          'Voltage': const DBusDouble(12.73),
          'Temperature': const DBusDouble(0),
          'TimeToEmpty': const DBusInt64(0),
          'TimeToFull': const DBusInt64(3600),
          'ChargeCycles': const DBusInt32(213),
          'ChargeThresholdSupported': const DBusBoolean(true),
          'ChargeThresholdEnabled': const DBusBoolean(false),
          'ChargeThresholdSettingsSupported': const DBusUint32(2),
          'ChargeStartThreshold': const DBusUint32(75),
          'ChargeEndThreshold': const DBusUint32(80),
        },
      );

      expect(battery, isNotNull);
      expect(battery!.displayName, 'AS3GXAE C536-49');
      expect(battery.state, UPowerBatteryState.fullyCharged);
      expect(battery.technology, UPowerBatteryTechnology.lithiumIon);
      expect(battery.healthPercentage, closeTo(78.2292, 0.0001));
      expect(battery.timeToEmpty, isNull);
      expect(battery.timeToFull, const Duration(hours: 1));
      expect(battery.chargeCycles, 213);
      expect(battery.chargeThresholdSupported, isTrue);
      expect(battery.chargeThresholdEnabled, isFalse);
      expect(battery.chargeStartThresholdSupported, isFalse);
      expect(battery.chargeEndThresholdSupported, isTrue);
      expect(battery.firmwareOptimizedChargingSupported, isFalse);
      expect(battery.chargeStartThreshold, 75);
      expect(battery.chargeEndThreshold, 80);
    },
  );

  test('filters peripheral devices and sanitizes invalid optional values', () {
    expect(
      parseUPowerSystemBattery('/stylus', <String, DBusValue>{
        'Type': const DBusUint32(10),
        'IsPresent': const DBusBoolean(true),
      }),
      isNull,
    );

    final battery = parseUPowerSystemBattery('/battery', <String, DBusValue>{
      'Type': const DBusUint32(2),
      'IsPresent': const DBusBoolean(true),
      'Percentage': const DBusDouble(double.nan),
      'Capacity': const DBusDouble(-1),
      'ChargeCycles': const DBusInt32(-1),
      'ChargeStartThreshold': const DBusUint32(0xffffffff),
      'ChargeEndThreshold': const DBusUint32(101),
    });

    expect(battery, isNotNull);
    expect(battery!.percentage, isNull);
    expect(battery.healthPercentage, isNull);
    expect(battery.chargeCycles, isNull);
    expect(battery.chargeStartThreshold, isNull);
    expect(battery.chargeEndThreshold, isNull);
  });

  test('snapshot updates only the requested battery threshold state', () {
    final first = _battery('/battery/one');
    final second = _battery('/battery/two');
    final snapshot = UPowerSnapshot(
      daemonVersion: '1.91.3',
      onBattery: false,
      batteries: <UPowerBattery>[first, second],
    );

    final updated = snapshot.withChargeThresholdEnabled('/battery/two', true);

    expect(updated.batteries.first.chargeThresholdEnabled, isFalse);
    expect(updated.batteries.last.chargeThresholdEnabled, isTrue);
  });
}

UPowerBattery _battery(String path) => UPowerBattery(
  objectPath: path,
  nativePath: path,
  vendor: '',
  model: '',
  serial: '',
  state: UPowerBatteryState.unknown,
  technology: UPowerBatteryTechnology.unknown,
  warningLevel: UPowerWarningLevel.none,
  percentage: null,
  healthPercentage: null,
  energy: null,
  energyFull: null,
  energyFullDesign: null,
  energyRate: null,
  voltage: null,
  temperature: null,
  timeToEmpty: null,
  timeToFull: null,
  chargeCycles: null,
  chargeThresholdSupported: true,
  chargeThresholdEnabled: false,
  chargeThresholdSettings: 0,
  chargeStartThreshold: null,
  chargeEndThreshold: null,
);
