import 'dart:io';

import '../../models/shell_power_status.dart';

class HomeClockInfo {
  const HomeClockInfo({
    required this.now,
    required this.locale,
    required this.power,
  });

  factory HomeClockInfo.fromShell({
    required DateTime now,
    required String locale,
    required ShellPowerStatus power,
  }) {
    return HomeClockInfo(
      now: now,
      locale: locale,
      power: HomePowerStatus.fromShell(power),
    );
  }

  final DateTime now;
  final String locale;
  final HomePowerStatus power;

  List<HomeThermalReading> get thermalReadings => power.thermalReadings;

  static String localeFromEnvironment(Map<String, String> environment) {
    final lcTime = _nonEmpty(environment['LC_TIME']);
    if (lcTime != null) {
      return lcTime;
    }

    final lang = _nonEmpty(environment['LANG']);
    if (lang != null) {
      return lang;
    }

    return Platform.localeName;
  }
}

class HomePowerStatus {
  const HomePowerStatus({
    required this.state,
    required this.capacity,
    required this.fastCharge,
    required this.voocCharging,
    required this.ppsCharging,
    required this.pdCharging,
    required this.ppsPower,
    required this.usbPower,
    required this.thermalCpuDeciC,
    required this.thermalSvoocDeciC,
    required this.thermalPmicDeciC,
    required this.thermalExp2DeciC,
  });

  static const unknown = HomePowerStatus(
    state: '',
    capacity: null,
    fastCharge: false,
    voocCharging: false,
    ppsCharging: false,
    pdCharging: false,
    ppsPower: 0,
    usbPower: 0,
    thermalCpuDeciC: null,
    thermalSvoocDeciC: null,
    thermalPmicDeciC: null,
    thermalExp2DeciC: null,
  );

  factory HomePowerStatus.fromShell(ShellPowerStatus power) {
    return HomePowerStatus(
      state: power.state,
      capacity: power.capacity,
      fastCharge: power.fastCharge,
      voocCharging: power.voocCharging,
      ppsCharging: power.ppsCharging,
      pdCharging: power.pdCharging,
      ppsPower: power.ppsPower,
      usbPower: power.usbPower,
      thermalCpuDeciC: power.thermalCpuDeciC,
      thermalSvoocDeciC: power.thermalSvoocDeciC,
      thermalPmicDeciC: power.thermalPmicDeciC,
      thermalExp2DeciC: power.thermalExp2DeciC,
    );
  }

  final String state;
  final int? capacity;
  final bool fastCharge;
  final bool voocCharging;
  final bool ppsCharging;
  final bool pdCharging;
  final int ppsPower;
  final int usbPower;
  final int? thermalCpuDeciC;
  final int? thermalSvoocDeciC;
  final int? thermalPmicDeciC;
  final int? thermalExp2DeciC;

  double get batteryLevel => ((capacity ?? 0) / 100).clamp(0.0, 1.0).toDouble();

  ShellChargeProtocol? get chargeProtocol {
    if (voocCharging) {
      return ShellChargeProtocol.vooc;
    }
    if (ppsCharging) {
      return ShellChargeProtocol.pps;
    }
    if (pdCharging) {
      return ShellChargeProtocol.powerDelivery;
    }
    if (fastCharge) {
      return ShellChargeProtocol.fast;
    }
    return null;
  }

  int? get chargeProtocolWatts {
    if (ppsCharging && ppsPower > 0) {
      return ppsPower;
    }
    if (pdCharging && usbPower > 0) {
      return usbPower;
    }
    return null;
  }

  List<HomeThermalReading> get thermalReadings {
    return [
      if (thermalCpuDeciC != null)
        HomeThermalReading(
          sensor: ShellThermalSensor.cpu,
          deciC: thermalCpuDeciC!,
        ),
      if (thermalSvoocDeciC != null)
        HomeThermalReading(
          sensor: ShellThermalSensor.svooc,
          deciC: thermalSvoocDeciC!,
        ),
      if (thermalPmicDeciC != null)
        HomeThermalReading(
          sensor: ShellThermalSensor.pmic,
          deciC: thermalPmicDeciC!,
        ),
      if (thermalExp2DeciC != null)
        HomeThermalReading(
          sensor: ShellThermalSensor.exp2,
          deciC: thermalExp2DeciC!,
        ),
    ];
  }
}

class HomeThermalReading {
  const HomeThermalReading({required this.sensor, required this.deciC});

  final ShellThermalSensor sensor;
  final int deciC;
}

String? _nonEmpty(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}
