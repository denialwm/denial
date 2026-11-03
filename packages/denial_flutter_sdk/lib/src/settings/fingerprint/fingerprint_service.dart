import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Discovery never queries enrolled fingerprints or claims the reader.
final fingerprintDeviceProvider = StreamProvider.autoDispose<bool>((
  ref,
) async* {
  final client = DBusClient.system();
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    unawaited(client.close());
  });
  final manager = DBusRemoteObject(
    client,
    name: 'net.reactivated.Fprint',
    path: DBusObjectPath('/net/reactivated/Fprint/Manager'),
  );
  while (!disposed) {
    var present = false;
    try {
      final reply = await manager
          .callMethod(
            'net.reactivated.Fprint.Manager',
            'GetDevices',
            [],
            replySignature: DBusSignature('ao'),
          )
          .timeout(const Duration(seconds: 3));
      present = (reply.returnValues.single as DBusArray).children.isNotEmpty;
    } catch (_) {
      /* Missing fprintd or a removed reader hides the section. */
    }
    if (disposed) return;
    yield present;
    await Future<void>.delayed(const Duration(seconds: 10));
  }
});

const fingerprintNames = <String>[
  'left-thumb',
  'left-index-finger',
  'left-middle-finger',
  'left-ring-finger',
  'left-little-finger',
  'right-thumb',
  'right-index-finger',
  'right-middle-finger',
  'right-ring-finger',
  'right-little-finger',
];

final fingerprintSessionProvider =
    Provider.autoDispose<FingerprintSettingsSession>((ref) {
      final session = FingerprintSettingsSession();
      ref.onDispose(session.dispose);
      return session;
    });

/// A private sudo process owns the authorization and all enrollment commands.
/// The lock PIN opens it; sudo's rule for that one command asks no password.
/// The PIN travels only through stdin, never argv, environment, or logs.
class FingerprintSettingsSession extends ChangeNotifier {
  bool authorized = false;
  bool authenticating = false;
  bool enrolling = false;
  int retryMilliseconds = 0;
  List<String> fingers = const [];
  String? status;
  int completed = 0;
  int total = 1;
  Process? _process;
  String? _pin;
  Timer? _authenticationTimeout;
  bool _disposed = false;
  int _generation = 0;

  Future<void> authenticate(String pin) async {
    if (_disposed || authenticating || authorized) return;
    if (!RegExp(r'^[0-9]{4,12}$').hasMatch(pin)) {
      status = 'wrong-pin';
      notifyListeners();
      return;
    }
    final generation = ++_generation;
    authenticating = true;
    status = null;
    _pin = pin;
    notifyListeners();
    try {
      final process = await Process.start(
        Platform.environment['DENIAL_PRIVILEGE_TOOL']?.trim().isNotEmpty == true
            ? Platform.environment['DENIAL_PRIVILEGE_TOOL']!.trim()
            : 'sudo',
        [
          '-n',
          '--',
          Platform.environment['DENIAL_COMPOSITOR_BINARY']?.trim().isNotEmpty ==
                  true
              ? Platform.environment['DENIAL_COMPOSITOR_BINARY']!.trim()
              : 'deniald',
          '--fingerprint-settings',
        ],
        environment: {'LC_ALL': 'C'},
      );
      if (_disposed || generation != _generation) {
        unawaited(process.stdin.close());
        process.kill();
        return;
      }
      _process = process;
      _authenticationTimeout = Timer(
        const Duration(seconds: 25),
        () => _fail('unavailable', generation),
      );
      process.stderr.drain<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (_disposed || generation != _generation) return;
            try {
              handleEvent((jsonDecode(line) as Map).cast<String, Object?>());
            } catch (_) {
              _fail('unavailable', generation);
            }
          }, onError: (Object _) => _fail('unavailable', generation));
      unawaited(
        process.exitCode.then((_) {
          if (!_disposed && generation == _generation) {
            _fail(authorized ? 'expired' : 'unavailable', generation);
          }
        }),
      );
    } catch (_) {
      _fail('unavailable', generation);
    }
  }

  @visibleForTesting
  void handleEvent(Map<String, Object?> event) {
    switch (event['event']) {
      case 'pin':
        final pin = _pin;
        _pin = null;
        if (pin != null) _process?.stdin.writeln(pin);
      case 'ready':
        if (!authenticating && !authorized) return;
        _pin = null;
        _authenticationTimeout?.cancel();
        authenticating = false;
        authorized = true;
        enrolling = false;
        fingers = List.unmodifiable(
          (event['fingers'] as List).whereType<String>().where(
            fingerprintNames.contains,
          ),
        );
      case 'wrong-pin' || 'pin-not-configured':
        _fail(event['event']! as String, _generation);
        return;
      case 'rate-limited':
        retryMilliseconds = (event['retry_ms'] as int? ?? 0).clamp(
          0,
          2147483647,
        );
        _fail('rate-limited', _generation);
        return;
      case 'unavailable':
        _fail('unavailable', _generation);
        return;
      case 'expired':
        _fail('expired', _generation);
        return;
      case 'enrollment':
        if (!authorized) return;
        status = event['status'] as String?;
        completed = (event['completed'] as int? ?? completed).clamp(0, 100);
        total = (event['total'] as int? ?? total).clamp(1, 100);
        enrolling = ![
          'cancelled',
          'enroll-completed',
          'enroll-failed',
          'enroll-duplicate',
          'enroll-data-full',
          'enroll-disconnected',
          'enroll-unknown-error',
        ].contains(status);
      case 'error':
        if (!authorized) return;
        status = event['code'] as String? ?? 'unavailable';
        retryMilliseconds = (event['retry_ms'] as int? ?? 0).clamp(
          0,
          2147483647,
        );
        enrolling = false;
      default:
        return;
    }
    if (!_disposed) notifyListeners();
  }

  void enroll(String finger) {
    if (!authorized ||
        enrolling ||
        !fingerprintNames.contains(finger) ||
        fingers.contains(finger)) {
      return;
    }
    enrolling = true;
    completed = 0;
    total = 1;
    status = 'preparing';
    _process?.stdin.writeln(
      jsonEncode({'command': 'enroll', 'finger': finger}),
    );
    notifyListeners();
  }

  void cancelEnrollment() {
    if (authorized && enrolling) {
      _process?.stdin.writeln(jsonEncode({'command': 'cancel'}));
    }
  }

  void _fail(String message, int generation) {
    if (_disposed || generation != _generation) return;
    _generation++;
    _pin = null;
    _authenticationTimeout?.cancel();
    final process = _process;
    _process = null;
    if (process != null) {
      _stopProcess(process);
    }
    authorized = false;
    authenticating = false;
    enrolling = false;
    fingers = const [];
    status = message;
    notifyListeners();
  }

  void _stopProcess(Process process) {
    unawaited(process.stdin.close().catchError((Object _) {}));
    // EOF lets the helper stop enrollment and release its device claim.
    unawaited(
      process.exitCode.timeout(const Duration(seconds: 4)).catchError((
        Object _,
      ) {
        process.kill();
        return -1;
      }),
    );
  }

  /// Called immediately on navigation away, before the page's exit animation.
  void close() {
    if (!_disposed) _fail('expired', _generation);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _pin = null;
    _authenticationTimeout?.cancel();
    final process = _process;
    if (process != null) {
      _stopProcess(process);
    }
    super.dispose();
  }
}
