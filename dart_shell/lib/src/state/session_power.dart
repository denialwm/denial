import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../platform/denial_bridge.dart';
import '../services/logind_service.dart';
import 'authentication.dart';
import 'shell_controller.dart';

enum SessionPowerAction {
  lock,
  logout,
  suspend,
  hibernate,
  reboot,
  powerOff;

  bool get requiresConfirmation =>
      this == SessionPowerAction.logout ||
      this == SessionPowerAction.reboot ||
      this == SessionPowerAction.powerOff;

  LogindAction? get logindAction => switch (this) {
    SessionPowerAction.suspend => LogindAction.suspend,
    SessionPowerAction.hibernate => LogindAction.hibernate,
    SessionPowerAction.reboot => LogindAction.reboot,
    SessionPowerAction.powerOff => LogindAction.powerOff,
    _ => null,
  };
}

enum SessionActionPermission {
  available,
  authenticationRequired,
  denied,
  unsupported,
  unavailable;

  bool get canRequest =>
      this == SessionActionPermission.available ||
      this == SessionActionPermission.authenticationRequired;
}

@immutable
class SessionActionAvailability {
  SessionActionAvailability({
    required this.permission,
    List<String> blockers = const <String>[],
  }) : blockers = List<String>.unmodifiable(blockers);

  const SessionActionAvailability.available()
    : permission = SessionActionPermission.available,
      blockers = const <String>[];

  final SessionActionPermission permission;
  final List<String> blockers;

  bool get enabled => permission.canRequest && blockers.isEmpty;

  bool get requiresAuthentication =>
      permission == SessionActionPermission.authenticationRequired;

  String? get unavailableReason {
    if (blockers.isNotEmpty) {
      return blockers.first;
    }
    return switch (permission) {
      SessionActionPermission.denied => 'Not authorized for this session',
      SessionActionPermission.unsupported => 'Not supported by this system',
      SessionActionPermission.unavailable => 'Session service unavailable',
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionActionAvailability &&
          other.permission == permission &&
          listEquals(other.blockers, blockers);

  @override
  int get hashCode => Object.hash(permission, Object.hashAll(blockers));
}

@immutable
class SessionPowerState {
  const SessionPowerState({
    required this.initialized,
    required this.snapshot,
    required this.busyAction,
    required this.confirmationAction,
    required this.error,
  });

  SessionPowerState.initial()
    : initialized = false,
      snapshot = LogindSnapshot.unavailable(),
      busyAction = null,
      confirmationAction = null,
      error = null;

  final bool initialized;
  final LogindSnapshot snapshot;
  final SessionPowerAction? busyAction;
  final SessionPowerAction? confirmationAction;
  final String? error;

  bool get busy => busyAction != null;

  SessionActionAvailability availabilityFor(SessionPowerAction action) {
    final logindAction = action.logindAction;
    if (logindAction == null) {
      return const SessionActionAvailability.available();
    }
    final capability = snapshot.capabilityFor(logindAction);
    final permission = switch (capability) {
      LogindCapability.available => SessionActionPermission.available,
      LogindCapability.authenticationRequired =>
        SessionActionPermission.authenticationRequired,
      LogindCapability.denied => SessionActionPermission.denied,
      LogindCapability.unsupported => SessionActionPermission.unsupported,
      LogindCapability.unavailable => SessionActionPermission.unavailable,
    };
    final blockers = snapshot
        .blockersFor(logindAction)
        .map((inhibitor) => inhibitor.description)
        .toSet()
        .take(3)
        .toList(growable: false);
    return SessionActionAvailability(
      permission: permission,
      blockers: blockers,
    );
  }

  SessionPowerState copyWith({
    bool? initialized,
    LogindSnapshot? snapshot,
    SessionPowerAction? busyAction,
    bool clearBusyAction = false,
    SessionPowerAction? confirmationAction,
    bool clearConfirmationAction = false,
    String? error,
    bool clearError = false,
  }) {
    return SessionPowerState(
      initialized: initialized ?? this.initialized,
      snapshot: snapshot ?? this.snapshot,
      busyAction: clearBusyAction ? null : busyAction ?? this.busyAction,
      confirmationAction: clearConfirmationAction
          ? null
          : confirmationAction ?? this.confirmationAction,
      error: clearError ? null : error ?? this.error,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionPowerState &&
          other.initialized == initialized &&
          other.snapshot == snapshot &&
          other.busyAction == busyAction &&
          other.confirmationAction == confirmationAction &&
          other.error == error;

  @override
  int get hashCode =>
      Object.hash(initialized, snapshot, busyAction, confirmationAction, error);
}

abstract interface class SessionRuntimeBackend {
  void lock();

  bool requestLogout();
}

class NativeSessionRuntimeBackend implements SessionRuntimeBackend {
  const NativeSessionRuntimeBackend({
    required AuthenticationController authentication,
    required DenialBridge bridge,
  }) : _authentication = authentication,
       _bridge = bridge;

  final AuthenticationController _authentication;
  final DenialBridge _bridge;

  @override
  void lock() => _authentication.lock();

  @override
  bool requestLogout() => _bridge.requestLogout();
}

final sessionPowerProvider =
    StateNotifierProvider<SessionPowerController, SessionPowerState>((ref) {
      return SessionPowerController(
        ref.read(logindServiceProvider),
        NativeSessionRuntimeBackend(
          authentication: ref.read(authenticationProvider.notifier),
          bridge: ref.read(denialBridgeProvider),
        ),
      );
    });

class SessionPowerController extends StateNotifier<SessionPowerState> {
  SessionPowerController(
    this._logind,
    this._runtime, {
    this.logoutWatchdog = const Duration(seconds: 5),
  }) : super(SessionPowerState.initial()) {
    _subscription = _logind.snapshots.listen(_handleSnapshot);
    unawaited(_initialize());
  }

  final LogindBackend _logind;
  final SessionRuntimeBackend _runtime;
  final Duration logoutWatchdog;
  late final StreamSubscription<LogindSnapshot> _subscription;
  Timer? _logoutTimer;
  bool _disposed = false;

  Future<void> _initialize() async {
    try {
      await _logind.start();
    } on Object {
      // The unavailable snapshot below is the user-visible result.
    }
    if (_disposed) {
      return;
    }
    state = state.copyWith(
      initialized: true,
      snapshot: _logind.currentSnapshot,
    );
  }

  void _handleSnapshot(LogindSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    state = state.copyWith(initialized: true, snapshot: snapshot);
  }

  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    state = state.copyWith(clearError: true);
    try {
      await _logind.refresh();
    } on Object {
      if (!_disposed) {
        state = state.copyWith(error: 'Could not refresh session controls');
      }
    }
  }

  Future<void> request(SessionPowerAction action) async {
    if (_disposed || state.busy || state.confirmationAction != null) {
      return;
    }
    final availability = state.availabilityFor(action);
    if (!availability.enabled) {
      state = state.copyWith(
        error: availability.unavailableReason ?? 'Action unavailable',
      );
      return;
    }
    if (action.requiresConfirmation) {
      state = state.copyWith(confirmationAction: action, clearError: true);
      return;
    }
    await _perform(action);
  }

  Future<void> confirm() async {
    final action = state.confirmationAction;
    if (_disposed || state.busy || action == null) {
      return;
    }
    state = state.copyWith(clearConfirmationAction: true, clearError: true);
    await _perform(action);
  }

  void cancelConfirmation() {
    if (_disposed || state.busy || state.confirmationAction == null) {
      return;
    }
    state = state.copyWith(clearConfirmationAction: true, clearError: true);
  }

  void clearError() {
    if (!_disposed && state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  Future<void> _perform(SessionPowerAction action) async {
    if (_disposed || state.busy) {
      return;
    }
    final availability = state.availabilityFor(action);
    if (!availability.enabled) {
      state = state.copyWith(
        error: availability.unavailableReason ?? 'Action unavailable',
      );
      return;
    }

    state = state.copyWith(busyAction: action, clearError: true);
    try {
      switch (action) {
        case SessionPowerAction.lock:
          _runtime.lock();
          if (!_disposed) {
            state = state.copyWith(clearBusyAction: true);
          }
        case SessionPowerAction.logout:
          if (!_runtime.requestLogout()) {
            throw const LogindActionUnavailableException(
              'The compositor did not accept the logout request',
            );
          }
          _logoutTimer?.cancel();
          _logoutTimer = Timer(logoutWatchdog, () {
            if (_disposed || state.busyAction != SessionPowerAction.logout) {
              return;
            }
            state = state.copyWith(
              clearBusyAction: true,
              error: 'The session did not close; you can try again',
            );
          });
        case SessionPowerAction.suspend ||
            SessionPowerAction.hibernate ||
            SessionPowerAction.reboot ||
            SessionPowerAction.powerOff:
          await _logind.perform(action.logindAction!);
          if (!_disposed) {
            state = state.copyWith(clearBusyAction: true);
          }
      }
    } on Object catch (error) {
      if (!_disposed) {
        state = state.copyWith(
          clearBusyAction: true,
          error: sessionPowerErrorMessage(error),
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _logoutTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

String sessionPowerErrorMessage(Object error) {
  if (error is LogindActionUnavailableException) {
    return error.message;
  }
  if (error is DBusMethodResponseException) {
    final name = error.errorName;
    if (name.contains('AccessDenied') ||
        name.contains('InteractiveAuthorizationRequired') ||
        name.contains('NotAuthorized')) {
      return 'Authorization was denied';
    }
    if (name.contains('Inhibit')) {
      return 'An application is preventing this action';
    }
    if (name.contains('NotSupported') || name.contains('SleepVerb')) {
      return 'This action is not supported by the system';
    }
    if (name.contains('ServiceUnknown') ||
        name.contains('NameHasNoOwner') ||
        name.contains('NoReply') ||
        name.contains('Disconnected')) {
      return 'The session service is unavailable';
    }
  }
  if (error is TimeoutException) {
    return 'The session service did not respond';
  }
  return 'The system could not complete the request';
}
