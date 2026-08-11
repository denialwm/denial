import 'dart:async';

import 'package:denial_dart_shell/src/platform/authentication_protocol.dart';
import 'package:denial_dart_shell/src/services/authentication_service.dart';
import 'package:denial_dart_shell/src/state/authentication.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native lock state wins and failed authentication remains locked', () {
    final service = _FakeAuthenticationService();
    addTearDown(service.dispose);
    final container = ProviderContainer.test(
      overrides: [authenticationServiceProvider.overrideWithValue(service)],
    );
    final controller = container.read(authenticationProvider.notifier);

    service.emit(_state(locked: true, available: true));
    expect(container.read(authenticationProvider).synchronized, isTrue);
    expect(container.read(authenticationProvider).locked, isTrue);

    controller.begin();
    expect(service.beginCount, 1);
    service.emit(_prompt(attemptId: 5, sequence: 2, message: 'Password:'));
    controller.respond('single-use-secret');
    expect(service.responses, <String>['single-use-secret']);
    expect(<Object?>[
      container.read(authenticationProvider).prompt?.message,
      container.read(authenticationProvider).resultMessage,
      container.read(authenticationProvider).statusMessage,
    ], isNot(contains('single-use-secret')));

    service.emit(
      _result(
        locked: true,
        available: true,
        attemptId: 5,
        message: 'Authentication failed. Try again.',
        cooldownMs: 750,
      ),
    );
    expect(container.read(authenticationProvider).locked, isTrue);
    expect(container.read(authenticationProvider).resultIsError, isTrue);
    expect(container.read(authenticationProvider).rateLimited, isTrue);
    controller.begin();
    expect(service.beginCount, 1);
  });

  test('cancellation targets only the active native attempt', () {
    final service = _FakeAuthenticationService();
    addTearDown(service.dispose);
    final container = ProviderContainer.test(
      overrides: [authenticationServiceProvider.overrideWithValue(service)],
    );
    final controller = container.read(authenticationProvider.notifier);

    service.emit(_state(locked: true, available: true));
    service.emit(_prompt(attemptId: 17, sequence: 4, message: 'Password:'));
    controller.cancel();
    expect(service.cancelledAttempts, <int>[17]);

    service.emit(
      _result(
        locked: true,
        available: true,
        attemptId: 17,
        message: 'Authentication cancelled',
        cancelled: true,
      ),
    );
    expect(container.read(authenticationProvider).locked, isTrue);
    expect(container.read(authenticationProvider).busy, isFalse);
    expect(container.read(authenticationProvider).prompt, isNull);
    expect(container.read(authenticationProvider).resultMessage, isNull);
  });

  test('only a native success event clears authoritative lock state', () {
    final service = _FakeAuthenticationService();
    addTearDown(service.dispose);
    final container = ProviderContainer.test(
      overrides: [authenticationServiceProvider.overrideWithValue(service)],
    );
    final controller = container.read(authenticationProvider.notifier);

    service.emit(_state(locked: true, available: true));
    controller.respond('ignored-ui-only-value');
    expect(service.responses, isEmpty);
    expect(container.read(authenticationProvider).locked, isTrue);

    service.emit(
      _result(
        locked: false,
        available: true,
        attemptId: 3,
        message: 'Authentication successful',
        success: true,
      ),
    );
    expect(container.read(authenticationProvider).locked, isFalse);
  });
}

AuthenticationPacket _state({required bool locked, required bool available}) {
  return AuthenticationPacket(
    kind: AuthenticationPacketKind.state,
    locked: locked,
    available: available,
    busy: false,
    rateLimited: false,
    attemptId: 0,
    argument: 0,
    payload: '',
  );
}

AuthenticationPacket _prompt({
  required int attemptId,
  required int sequence,
  required String message,
}) {
  return AuthenticationPacket(
    kind: AuthenticationPacketKind.prompt,
    locked: true,
    available: true,
    busy: true,
    rateLimited: false,
    attemptId: attemptId,
    argument: sequence,
    payload: message,
    promptStyle: AuthenticationPromptStyle.echoOff,
  );
}

AuthenticationPacket _result({
  required bool locked,
  required bool available,
  required int attemptId,
  required String message,
  int cooldownMs = 0,
  bool success = false,
  bool cancelled = false,
}) {
  return AuthenticationPacket(
    kind: AuthenticationPacketKind.result,
    locked: locked,
    available: available,
    busy: false,
    rateLimited: cooldownMs > 0,
    attemptId: attemptId,
    argument: cooldownMs,
    payload: message,
    success: success,
    cancelled: cancelled,
  );
}

class _FakeAuthenticationService implements AuthenticationService {
  final StreamController<AuthenticationPacket> _events =
      StreamController<AuthenticationPacket>.broadcast(sync: true);
  final List<String> responses = <String>[];
  final List<int> cancelledAttempts = <int>[];
  int beginCount = 0;
  int synchronizeCount = 0;
  int lockCount = 0;

  @override
  Stream<AuthenticationPacket> get events => _events.stream;

  void emit(AuthenticationPacket packet) => _events.add(packet);

  @override
  void begin() => beginCount += 1;

  @override
  void cancel({required int attemptId}) {
    cancelledAttempts.add(attemptId);
  }

  @override
  void lock() => lockCount += 1;

  @override
  void respond({
    required int attemptId,
    required int promptSequence,
    required String response,
  }) {
    responses.add(response);
  }

  @override
  void synchronize() => synchronizeCount += 1;

  @override
  void dispose() {
    _events.close();
  }
}
