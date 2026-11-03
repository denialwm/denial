import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utf8_size.dart';

/// Digits a lock PIN may have; deniald enforces the same bounds.
const int lockPinMinLength = 4;
const int lockPinMaxLength = 12;

bool isValidLockPin(String pin) =>
    pin.length >= lockPinMinLength &&
    pin.length <= lockPinMaxLength &&
    RegExp(r'^[0-9]+$').hasMatch(pin);

enum LockPinOutcome {
  saved,
  cleared,
  authenticationFailed,
  wrongPin,
  invalidPin,
  unavailable,
}

/// The configured PIN length, 0 when the lock screen asks for the password.
final lockPinLengthProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(lockPinServiceProvider).length(),
);

final lockPinServiceProvider = Provider<LockPinService>(
  (ref) => const LockPinService(),
);

/// Settings side of the optional lock PIN. `deniald --lock-pin` runs as the
/// session user and verifies the account password, or the current PIN for a
/// change, itself before it writes or removes the PIN. Secrets travel one per stdin line, never through argv,
/// the environment or logs.
class LockPinService {
  const LockPinService();

  static const Duration _timeout = Duration(seconds: 40);

  Future<int> length() async {
    final reply = await _run(const ['status']);
    return reply?['event'] == 'status' ? (reply!['length'] as int? ?? 0) : 0;
  }

  /// A disabled native PIN retains its credential and still needs the current
  /// PIN for a change. This does not mean PIN unlock is currently enabled.
  Future<bool> requiresCurrentPin() async {
    final reply = await _run(const ['status']);
    return reply?['requires_current_pin'] == true;
  }

  Future<LockPinOutcome> save({
    required String password,
    required String pin,
    String? currentPin,
  }) async {
    if (!_validPassword(password)) return LockPinOutcome.authenticationFailed;
    if (!isValidLockPin(pin)) return LockPinOutcome.invalidPin;
    final current = currentPin?.isNotEmpty == true ? currentPin : null;
    return _outcome(await _run(['set', password, pin, ?current]));
  }

  /// Replaces the PIN in use, proven by the current PIN alone.
  Future<LockPinOutcome> change({
    required String currentPin,
    required String pin,
  }) async {
    if (!isValidLockPin(pin)) return LockPinOutcome.invalidPin;
    if (!RegExp(r'^[0-9]{4,12}$').hasMatch(currentPin)) {
      return LockPinOutcome.wrongPin;
    }
    return _outcome(await _run(['change', currentPin, pin]));
  }

  Future<LockPinOutcome> clear({required String password}) async {
    if (!_validPassword(password)) return LockPinOutcome.authenticationFailed;
    return _outcome(await _run(['clear', password]));
  }

  static bool _validPassword(String password) =>
      password.isNotEmpty &&
      fitsUtf8ByteLimit(password, 4000) &&
      !password.contains(RegExp(r'[\n\r\x00]'));

  static LockPinOutcome _outcome(Map<String, Object?>? reply) =>
      switch (reply?['event']) {
        'saved' => LockPinOutcome.saved,
        'cleared' => LockPinOutcome.cleared,
        'authentication-failed' => LockPinOutcome.authenticationFailed,
        'wrong-pin' => LockPinOutcome.wrongPin,
        'invalid-pin' => LockPinOutcome.invalidPin,
        _ => LockPinOutcome.unavailable,
      };

  Future<Map<String, Object?>?> _run(List<String> lines) async {
    final configured = Platform.environment['DENIAL_COMPOSITOR_BINARY']?.trim();
    final Process process;
    try {
      process = await Process.start(
        configured?.isNotEmpty == true ? configured! : 'deniald',
        const ['--lock-pin'],
        environment: const {'LC_ALL': 'C'},
      );
    } on Object {
      return null;
    }
    final stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    unawaited(process.stderr.drain<void>());
    try {
      for (final line in lines) {
        process.stdin.writeln(line);
      }
      await process.stdin.close();
      final output = await stdout.timeout(_timeout);
      await process.exitCode.timeout(_timeout);
      return output.isEmpty
          ? null
          : (jsonDecode(output.last) as Map).cast<String, Object?>();
    } on Object {
      process.kill();
      return null;
    }
  }
}
