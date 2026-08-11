import 'package:flutter/foundation.dart';

import 'battery_status.dart';

enum ShellChargeProtocol { vooc, pps, powerDelivery, fast }

enum ShellThermalSensor { cpu, svooc, pmic, exp2 }

@immutable
class ShellPowerStatus {
  const ShellPowerStatus({
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

  factory ShellPowerStatus.fromFields(Map<String, String> fields) {
    return ShellPowerStatus(
      state: (fields['STATE'] ?? '').toLowerCase(),
      capacity: _parseInt(fields['CAPACITY']),
      fastCharge: _parseFlag(fields['FAST_CHARGE']),
      voocCharging: _parseFlag(fields['VOOC_CHARGING']),
      ppsCharging: _parseFlag(fields['PPS_CHARGING']),
      pdCharging: _parseFlag(fields['PD_CHARGING']),
      ppsPower: _parseInt(fields['PPS_POWER']) ?? 0,
      usbPower: _parseInt(fields['USB_POWER_W']) ?? 0,
      thermalCpuDeciC: _parseThermal(fields['THERMAL_CPU_DECI_C']),
      thermalSvoocDeciC: _parseThermal(fields['THERMAL_SVOOC_DECI_C']),
      thermalPmicDeciC: _parseThermal(fields['THERMAL_PMIC_DECI_C']),
      thermalExp2DeciC: _parseThermal(fields['THERMAL_EXP2_DECI_C']),
    );
  }

  static const unknown = ShellPowerStatus(
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

  bool get charging {
    return state == 'charging' ||
        fastCharge ||
        voocCharging ||
        ppsCharging ||
        pdCharging;
  }

  double get batteryLevel {
    return ((capacity ?? 0) / 100).clamp(0.0, 1.0).toDouble();
  }

  BatteryStatus get batteryStatus {
    return BatteryStatus(capacity: capacity, charging: charging);
  }

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

  List<ShellThermalReading> get thermalReadings {
    return [
      if (thermalCpuDeciC != null)
        ShellThermalReading(
          sensor: ShellThermalSensor.cpu,
          deciC: thermalCpuDeciC!,
        ),
      if (thermalSvoocDeciC != null)
        ShellThermalReading(
          sensor: ShellThermalSensor.svooc,
          deciC: thermalSvoocDeciC!,
        ),
      if (thermalPmicDeciC != null)
        ShellThermalReading(
          sensor: ShellThermalSensor.pmic,
          deciC: thermalPmicDeciC!,
        ),
      if (thermalExp2DeciC != null)
        ShellThermalReading(
          sensor: ShellThermalSensor.exp2,
          deciC: thermalExp2DeciC!,
        ),
    ];
  }

  @override
  bool operator ==(Object other) {
    return other is ShellPowerStatus &&
        other.state == state &&
        other.capacity == capacity &&
        other.fastCharge == fastCharge &&
        other.voocCharging == voocCharging &&
        other.ppsCharging == ppsCharging &&
        other.pdCharging == pdCharging &&
        other.ppsPower == ppsPower &&
        other.usbPower == usbPower &&
        other.thermalCpuDeciC == thermalCpuDeciC &&
        other.thermalSvoocDeciC == thermalSvoocDeciC &&
        other.thermalPmicDeciC == thermalPmicDeciC &&
        other.thermalExp2DeciC == thermalExp2DeciC;
  }

  @override
  int get hashCode {
    return Object.hash(
      state,
      capacity,
      fastCharge,
      voocCharging,
      ppsCharging,
      pdCharging,
      ppsPower,
      usbPower,
      thermalCpuDeciC,
      thermalSvoocDeciC,
      thermalPmicDeciC,
      thermalExp2DeciC,
    );
  }
}

@immutable
class ShellThermalReading {
  const ShellThermalReading({required this.sensor, required this.deciC});

  final ShellThermalSensor sensor;
  final int deciC;
}

bool _parseFlag(String? value) {
  final parsed = int.tryParse(value ?? '');
  return parsed != null && parsed != 0;
}

int? _parseInt(String? value) {
  return int.tryParse(value ?? '');
}

int? _parseThermal(String? value) {
  final parsed = _parseInt(value);
  if (parsed == null || parsed <= -10000) {
    return null;
  }
  return parsed;
}
