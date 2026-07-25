import 'dart:async';

import 'package:denial_dart_shell/src/services/logind_service.dart';
import 'package:denial_dart_shell/src/state/session_power.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'immediate actions serialize requests and follow service signals',
    () async {
      final logind = _FakeLogind(_snapshot());
      final runtime = _FakeRuntime();
      final harness = _sessionPowerHarness(logind, runtime);
      final controller = harness.controller;
      await _settle();

      controller.request(SessionPowerAction.lock);
      expect(runtime.lockCalls, 1);

      logind.gate = Completer<void>();
      final first = controller.request(SessionPowerAction.suspend);
      final duplicate = controller.request(SessionPowerAction.suspend);
      expect(logind.actions, <LogindAction>[LogindAction.suspend]);
      expect(
        harness.container.read(sessionPowerProvider).busyAction,
        SessionPowerAction.suspend,
      );
      logind.gate!.complete();
      await Future.wait(<Future<void>>[first, duplicate]);
      expect(harness.container.read(sessionPowerProvider).busyAction, isNull);

      logind.emit(LogindSnapshot.unavailable());
      expect(
        harness.container.read(sessionPowerProvider).snapshot.serviceAvailable,
        isFalse,
      );
      expect(
        harness.container
            .read(sessionPowerProvider)
            .availabilityFor(SessionPowerAction.suspend)
            .enabled,
        isFalse,
      );
    },
  );

  test(
    'destructive actions require confirmation and duplicate taps coalesce',
    () async {
      final logind = _FakeLogind(_snapshot());
      final runtime = _FakeRuntime();
      final harness = _sessionPowerHarness(
        logind,
        runtime,
        logoutWatchdog: const Duration(days: 1),
      );
      final controller = harness.controller;
      await _settle();

      await controller.request(SessionPowerAction.logout);
      expect(
        harness.container.read(sessionPowerProvider).confirmationAction,
        SessionPowerAction.logout,
      );
      expect(runtime.logoutCalls, 0);

      controller.cancelConfirmation();
      expect(
        harness.container.read(sessionPowerProvider).confirmationAction,
        isNull,
      );
      await controller.request(SessionPowerAction.logout);
      final first = controller.confirm();
      final duplicate = controller.confirm();
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(runtime.logoutCalls, 1);
      expect(
        harness.container.read(sessionPowerProvider).busyAction,
        SessionPowerAction.logout,
      );
      await controller.request(SessionPowerAction.logout);
      expect(runtime.logoutCalls, 1);
    },
  );

  test('block inhibitors and denied capabilities never cross D-Bus', () async {
    final blocker = LogindInhibitor(
      what: <String>{'sleep'},
      who: 'Video editor',
      why: 'Export in progress',
      mode: 'block',
      uid: 1000,
      pid: 22,
    );
    final logind = _FakeLogind(
      _snapshot(
        hibernate: LogindCapability.denied,
        inhibitors: <LogindInhibitor>[blocker],
      ),
    );
    final harness = _sessionPowerHarness(logind, _FakeRuntime());
    final controller = harness.controller;
    await _settle();

    await controller.request(SessionPowerAction.suspend);
    expect(logind.actions, isEmpty);
    expect(
      harness.container.read(sessionPowerProvider).error,
      'Video editor: Export in progress',
    );

    controller.clearError();
    logind.emit(_snapshot(hibernate: LogindCapability.denied));
    await controller.request(SessionPowerAction.hibernate);
    expect(logind.actions, isEmpty);
    expect(
      harness.container.read(sessionPowerProvider).error,
      'Not authorized for this session',
    );
  });

  test(
    'challenge capability remains actionable and errors are sanitized',
    () async {
      final logind = _FakeLogind(
        _snapshot(suspend: LogindCapability.authenticationRequired),
      );
      final harness = _sessionPowerHarness(logind, _FakeRuntime());
      final controller = harness.controller;
      await _settle();

      final availability = harness.container
          .read(sessionPowerProvider)
          .availabilityFor(SessionPowerAction.suspend);
      expect(availability.enabled, isTrue);
      expect(availability.requiresAuthentication, isTrue);

      logind.error = Exception('private implementation details');
      await controller.request(SessionPowerAction.suspend);
      expect(
        harness.container.read(sessionPowerProvider).error,
        'The system could not complete the request',
      );
      expect(
        harness.container.read(sessionPowerProvider).error,
        isNot(contains('private')),
      );
    },
  );
}

({ProviderContainer container, SessionPowerController controller})
_sessionPowerHarness(
  _FakeLogind logind,
  SessionRuntimeBackend runtime, {
  Duration logoutWatchdog = const Duration(seconds: 5),
}) {
  addTearDown(logind.dispose);
  final container = ProviderContainer.test(
    overrides: [
      logindServiceProvider.overrideWithValue(logind),
      sessionRuntimeBackendProvider.overrideWithValue(runtime),
      sessionLogoutWatchdogProvider.overrideWithValue(logoutWatchdog),
    ],
  );
  return (
    container: container,
    controller: container.read(sessionPowerProvider.notifier),
  );
}

class _FakeLogind implements LogindBackend {
  _FakeLogind(this._current);

  final StreamController<LogindSnapshot> _snapshots =
      StreamController<LogindSnapshot>.broadcast(sync: true);
  LogindSnapshot _current;
  final List<LogindAction> actions = <LogindAction>[];
  Completer<void>? gate;
  Object? error;

  @override
  LogindSnapshot get currentSnapshot => _current;

  @override
  Stream<LogindSnapshot> get snapshots => _snapshots.stream;

  void emit(LogindSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> start() async => emit(_current);

  @override
  Future<void> refresh() async => emit(_current);

  @override
  Future<void> perform(LogindAction action) async {
    actions.add(action);
    await gate?.future;
    if (error case final value?) {
      throw value;
    }
  }

  @override
  Future<void> dispose() => _snapshots.close();
}

class _FakeRuntime implements SessionRuntimeBackend {
  int lockCalls = 0;
  int logoutCalls = 0;
  bool logoutAccepted = true;

  @override
  void lock() => lockCalls += 1;

  @override
  bool requestLogout() {
    logoutCalls += 1;
    return logoutAccepted;
  }
}

LogindSnapshot _snapshot({
  LogindCapability suspend = LogindCapability.available,
  LogindCapability hibernate = LogindCapability.available,
  LogindCapability reboot = LogindCapability.available,
  LogindCapability powerOff = LogindCapability.available,
  List<LogindInhibitor> inhibitors = const <LogindInhibitor>[],
}) {
  return LogindSnapshot(
    serviceAvailable: true,
    capabilities: <LogindAction, LogindCapability>{
      LogindAction.suspend: suspend,
      LogindAction.hibernate: hibernate,
      LogindAction.reboot: reboot,
      LogindAction.powerOff: powerOff,
    },
    inhibitors: inhibitors,
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
