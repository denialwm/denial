import 'dart:io';

import 'shell_power_status.dart';

class ShellClockInfo {
  const ShellClockInfo({
    required this.now,
    required this.locale,
    required this.power,
  });

  final DateTime now;
  final String locale;
  final ShellPowerStatus power;

  List<ShellThermalReading> get thermalReadings => power.thermalReadings;

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

String? _nonEmpty(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}
