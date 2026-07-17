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
