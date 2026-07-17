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

  String get timeLine {
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get dateLine {
    final names = _DateNames.forLocale(locale);
    return '${names.weekdays[now.weekday - 1]} ${now.day} '
        '${names.months[now.month - 1]}';
  }

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

  String get protocolLabel {
    if (voocCharging) {
      return 'VOOC';
    }
    if (ppsCharging) {
      return 'PPS';
    }
    if (pdCharging) {
      return 'PD';
    }
    if (fastCharge) {
      return 'FAST';
    }
    return '';
  }

  String get protocolDetail {
    if (ppsCharging && ppsPower > 0) {
      return '${ppsPower}W';
    }
    if (pdCharging && usbPower > 0) {
      return '${usbPower}W';
    }
    return '';
  }

  String get displayState {
    return switch (state) {
      'charging' => 'Charging',
      'discharging' => 'Discharging',
      'idle' => 'Idle',
      _ => '',
    };
  }

  String get displayLine {
    final batteryCapacity = capacity;
    if (batteryCapacity == null) {
      return '';
    }

    final currentState = displayState;
    if (currentState.isEmpty) {
      return '$batteryCapacity%';
    }
    return '$currentState $batteryCapacity%';
  }

  List<HomeThermalReading> get thermalReadings {
    return [
      if (thermalCpuDeciC != null)
        HomeThermalReading(label: 'CPU', deciC: thermalCpuDeciC!),
      if (thermalSvoocDeciC != null)
        HomeThermalReading(label: 'SVOOC', deciC: thermalSvoocDeciC!),
      if (thermalPmicDeciC != null)
        HomeThermalReading(label: 'PMIC', deciC: thermalPmicDeciC!),
      if (thermalExp2DeciC != null)
        HomeThermalReading(label: 'EXP2', deciC: thermalExp2DeciC!),
    ];
  }
}

class HomeThermalReading {
  const HomeThermalReading({
    required this.label,
    required this.deciC,
  });

  final String label;
  final int deciC;

  String get value => '${(deciC / 10).round()}\u00b0C';
}

class _DateNames {
  const _DateNames({
    required this.weekdays,
    required this.months,
  });

  factory _DateNames.forLocale(String locale) {
    final normalized = locale.toLowerCase();
    if (normalized.startsWith('it')) {
      return italian;
    }
    return english;
  }

  final List<String> weekdays;
  final List<String> months;

  static const english = _DateNames(
    weekdays: [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ],
    months: [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ],
  );

  static const italian = _DateNames(
    weekdays: [
      'Lunedi',
      'Martedi',
      'Mercoledi',
      'Giovedi',
      'Venerdi',
      'Sabato',
      'Domenica',
    ],
    months: [
      'Gennaio',
      'Febbraio',
      'Marzo',
      'Aprile',
      'Maggio',
      'Giugno',
      'Luglio',
      'Agosto',
      'Settembre',
      'Ottobre',
      'Novembre',
      'Dicembre',
    ],
  );
}

String? _nonEmpty(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}
