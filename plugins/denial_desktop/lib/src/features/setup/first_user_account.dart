import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/settings.dart';

/// The program that makes the first person's account, named by the session
/// that starts Denial before the system has one (Phonewave's denial-setup
/// session sets `DENIAL_FIRST_USER_HELPER`). While it is set the shell shows
/// its setup instead of the lock screen and home; without it, never.
///
/// The program runs through pkexec as
/// `HELPER USERNAME FULL_NAME DEVICE_NAME LANGUAGE TIME_ZONE`, reads the
/// password from its first line of input and the lock PIN, six digits or
/// empty, from its second. Its status: 0 made; 4 made, but a system setting
/// (name, time zone, language) failed; 5 made, but the PIN was not set; 3 an
/// account already exists; 2 it refused what it was given; anything else the
/// account was not made. `HELPER --fingerprint` runs the fingerprint session
/// for that account ([FingerprintSettingsSession]); `HELPER --start` starts
/// the session again as it.
final firstUserHelperProvider = Provider<String?>((ref) {
  final helper = ref
      .watch(runtimePathsProvider)
      .environment['DENIAL_FIRST_USER_HELPER'];
  return helper != null && helper.startsWith('/') ? helper : null;
});

enum SetupLanguage {
  english('en'),
  simplifiedChinese('zh');

  const SetupLanguage(this.code);

  /// What the helper takes.
  final String code;
}

/// What setup hands to the helper.
class FirstUserAccount {
  const FirstUserAccount({
    required this.username,
    required this.fullName,
    required this.password,
    this.pin = '',
    required this.deviceName,
    required this.language,
    required this.timeZone,
  });

  final String username;
  final String fullName;
  final String password;

  /// The lock PIN; empty sets none.
  final String pin;
  final String deviceName;
  final SetupLanguage language;

  /// Empty keeps the system's.
  final String timeZone;

  static final _username = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

  static bool validUsername(String value) => _username.hasMatch(value);

  /// What deniald takes for a new PIN.
  static bool validPin(String value) => RegExp(r'^[0-9]{6}$').hasMatch(value);

  static bool validFullName(String value) =>
      value.trim().isNotEmpty && !value.contains(RegExp(r'[:\n\t]'));

  /// A username from a full name: its first word, in the letters a username
  /// may hold. Names in other scripts give none, and the person types one.
  static String suggestUsername(String fullName) {
    final words = fullName.trim().toLowerCase().split(RegExp(r'\s+'));
    final kept = words.first.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    final name = kept.length > 32 ? kept.substring(0, 32) : kept;
    return validUsername(name) ? name : '';
  }
}

enum FirstUserOutcome { made, madeWithoutPin, exists, notAllowed, failed }

class FirstUserResult {
  const FirstUserResult(this.outcome, [this.message = '']);

  final FirstUserOutcome outcome;

  /// The helper's own words, when it failed.
  final String message;
}

Future<FirstUserResult> makeFirstUser(
  String helper,
  FirstUserAccount account,
) async {
  final Process process;
  try {
    process = await Process.start('pkexec', [
      helper,
      account.username,
      account.fullName.trim(),
      account.deviceName.trim(),
      account.language.code,
      account.timeZone,
    ]);
  } on ProcessException catch (error) {
    return FirstUserResult(FirstUserOutcome.failed, error.message);
  }
  final stderr = process.stderr.transform(utf8.decoder).join();
  unawaited(process.stdout.drain<void>());
  process.stdin
    ..writeln(account.password)
    ..writeln(account.pin);
  await process.stdin.close();
  final status = await process.exitCode;
  final message = (await stderr).trim();
  return switch (status) {
    0 || 4 => const FirstUserResult(FirstUserOutcome.made),
    5 => const FirstUserResult(FirstUserOutcome.madeWithoutPin),
    3 => const FirstUserResult(FirstUserOutcome.exists),
    // pkexec's own: polkit did not allow it.
    126 || 127 => const FirstUserResult(FirstUserOutcome.notAllowed),
    _ => FirstUserResult(FirstUserOutcome.failed, message),
  };
}

/// The fingerprint session for the account the helper made.
FingerprintSettingsSession firstUserFingerprints(String helper) =>
    FingerprintSettingsSession(command: ['pkexec', helper, '--fingerprint']);

/// Starts the session again as the account the helper made; the helper's
/// message when it could not.
Future<String?> startFirstUser(String helper) async {
  try {
    final result = await Process.run('pkexec', [helper, '--start']);
    return result.exitCode == 0 ? null : '${result.stderr}'.trim();
  } on ProcessException catch (error) {
    return error.message;
  }
}

/// The time zones a person picks from, tzdata's own list, and the system's.
class TimeZoneChoices {
  const TimeZoneChoices(this.zones, this.current);

  final List<String> zones;
  final String current;

  static const _zoneinfo = '/usr/share/zoneinfo';

  static Future<TimeZoneChoices> read() async {
    final zones = <String>{'UTC'};
    try {
      final table = await File('$_zoneinfo/zone1970.tab').readAsLines();
      for (final line in table) {
        if (line.startsWith('#')) continue;
        final fields = line.split('\t');
        if (fields.length >= 3) zones.add(fields[2]);
      }
    } on FileSystemException {
      // Without tzdata the system keeps its zone.
    }
    var current = '';
    try {
      final target = await File('/etc/localtime').resolveSymbolicLinks();
      final index = target.indexOf('/zoneinfo/');
      if (index >= 0) current = target.substring(index + '/zoneinfo/'.length);
    } on FileSystemException {
      // No /etc/localtime: the system runs on UTC.
    }
    return TimeZoneChoices(zones.toList()..sort(), current);
  }

  /// How a zone reads in the list: its city, then its region.
  static String label(String zone) {
    final parts = zone.replaceAll('_', ' ').split('/');
    return parts.length == 1
        ? parts.single
        : '${parts.last} · ${parts.sublist(0, parts.length - 1).join(' / ')}';
  }
}

/// What the device calls itself: the device tree's model on a phone, the
/// firmware's product name on a computer.
Future<String> readDeviceModel() async {
  for (final path in const [
    '/sys/firmware/devicetree/base/model',
    '/sys/class/dmi/id/product_name',
  ]) {
    try {
      final model = (await File(
        path,
      ).readAsString()).replaceAll('\u0000', '').trim();
      if (model.isNotEmpty) return model;
    } on FileSystemException {
      continue;
    }
  }
  return 'Denial';
}
