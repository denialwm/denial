import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef LockRequestChanged = void Function(bool locked);

/// Event-triggered compatibility bridge for legacy `denia-lock` callers.
///
/// Native compositor IPC is the primary command path and native state is the
/// security authority. A request value of `1` may only ask native code to lock;
/// `0` is an acknowledgement and can never unlock the session. The secure-state
/// file mirrors native state for the old powerd wait/skip contract.
class LockStateRepository {
  LockStateRepository({
    Map<String, String> environment = const <String, String>{},
    String? requestPath,
    String? secureStatePath,
  }) : requestPath = requestPath ?? _defaultRequestPath(environment),
       secureStatePath =
           secureStatePath ?? _defaultSecureStatePath(environment);

  final String requestPath;
  final String secureStatePath;
  StreamSubscription<FileSystemEvent>? _watchSubscription;
  LockRequestChanged? _onChanged;
  bool? _lastRequestedLocked;
  bool _polling = false;
  bool _pollQueued = false;

  void start({required LockRequestChanged onChanged}) {
    _onChanged = onChanged;
    unawaited(_startWatcher());
    unawaited(_poll());
  }

  void dispose() {
    unawaited(_watchSubscription?.cancel());
    _watchSubscription = null;
    _onChanged = null;
  }

  void acknowledgeUnlocked() {
    _lastRequestedLocked = false;
    unawaited(_writeFlag(requestPath, false));
  }

  void publishSecure(bool secure) {
    unawaited(_writeFlag(secureStatePath, secure));
  }

  Future<void> _startWatcher() async {
    try {
      final directory = File(requestPath).parent;
      await directory.create(recursive: true);
      if (_onChanged == null) {
        return;
      }
      _watchSubscription = directory.watch().listen(
        (event) {
          if (event.path == requestPath) {
            unawaited(_poll());
          }
        },
        onError: (Object error) {
          debugPrint('denia lock: file watch failed: $error');
        },
      );
    } on FileSystemException catch (error) {
      debugPrint('denia lock: file watch unavailable: $error');
    }
  }

  Future<void> _poll() async {
    if (_polling) {
      _pollQueued = true;
      return;
    }

    _polling = true;
    try {
      do {
        _pollQueued = false;
        final requested = await _readFlag(requestPath);
        if (_onChanged == null) {
          return;
        }
        if (_lastRequestedLocked != requested) {
          _lastRequestedLocked = requested;
          if (requested) {
            _onChanged?.call(true);
          }
        }
      } while (_pollQueued);
    } finally {
      _polling = false;
    }
  }

  static Future<bool> _readFlag(String path) async {
    try {
      return (await File(path).readAsString()).trim() == '1';
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) {
        return false;
      }
      debugPrint('denia lock: failed to read $path: $error');
      return false;
    }
  }

  static Future<void> _writeFlag(String path, bool enabled) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(enabled ? '1\n' : '0\n', flush: true);
    } on FileSystemException catch (error) {
      debugPrint('denia lock: failed to write $path: $error');
    }
  }

  static String _defaultRequestPath(Map<String, String> environment) {
    final runtime = environment['XDG_RUNTIME_DIR'] ?? '/tmp';
    return environment['DENIA_LOCK_REQUEST_STATE'] ??
        '$runtime/denia-lock-request';
  }

  static String _defaultSecureStatePath(Map<String, String> environment) {
    final runtime = environment['XDG_RUNTIME_DIR'] ?? '/tmp';
    return environment['DENIA_LOCK_SECURE_STATE'] ??
        '$runtime/denia-lock-secure';
  }
}
