import 'package:denial_dart_shell/src/models/battery_status.dart';
import 'package:denial_dart_shell/src/models/shell_power_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('standard battery overrides stale extended capacity only', () {
    const extended = ShellPowerStatus(
      state: 'charging',
      capacity: 50,
      fastCharge: true,
      voocCharging: true,
      ppsCharging: false,
      pdCharging: false,
      ppsPower: 0,
      usbPower: 11,
      thermalCpuDeciC: 410,
      thermalSvoocDeciC: 390,
      thermalPmicDeciC: null,
      thermalExp2DeciC: null,
    );

    final effective = extended.withStandardBattery(
      const BatteryStatus(capacity: 7, charging: false),
    );

    expect(effective.capacity, 7);
    expect(effective.state, 'discharging');
    expect(effective.voocCharging, isTrue);
    expect(effective.usbPower, 11);
    expect(effective.thermalCpuDeciC, 410);
  });

  test('missing standard battery leaves the extended state untouched', () {
    expect(
      ShellPowerStatus.unknown.withStandardBattery(BatteryStatus.unknown),
      same(ShellPowerStatus.unknown),
    );
  });
}
