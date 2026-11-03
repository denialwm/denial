import 'package:denial_flutter_sdk/service_backends.dart'
    show AuthenticationPacket, AuthenticationPacketKind;

import 'dart:async';
import 'dart:ui' show Rect;

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/state.dart';
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

  test('credential packets size the PIN without touching lock state', () {
    final service = _FakeAuthenticationService();
    addTearDown(service.dispose);
    final container = ProviderContainer.test(
      overrides: [authenticationServiceProvider.overrideWithValue(service)],
    );
    final controller = container.read(authenticationProvider.notifier);

    service.emit(_state(locked: true, available: true));
    service.emit(_credential(pinLength: 6));
    final state = container.read(authenticationProvider);
    expect(state.pinLength, 6);
    expect(state.pinConfigured, isTrue);
    expect(state.locked, isTrue);
    expect(state.rateLimited, isFalse);

    controller.begin(password: true);
    expect(service.passwordBeginCount, 1);
    service.emit(
      _prompt(
        attemptId: 3,
        sequence: 1,
        message: 'PIN',
        style: AuthenticationPromptStyle.pin,
      ),
    );
    final prompt = container.read(authenticationProvider).prompt!;
    expect(prompt.isPin, isTrue);
    expect(prompt.obscure, isTrue);
    expect(prompt.requiresResponse, isTrue);
    expect(container.read(authenticationProvider).pinLength, 6);

    service.emit(_credential(pinLength: 0));
    expect(container.read(authenticationProvider).pinConfigured, isFalse);
  });

  test('credential packets report the reader and its sensor', () {
    final service = _FakeAuthenticationService();
    addTearDown(service.dispose);
    final container = ProviderContainer.test(
      overrides: [authenticationServiceProvider.overrideWithValue(service)],
    );
    container.read(authenticationProvider);

    service.emit(
      _credential(
        pinLength: 4,
        payload:
            '{"fingerprint":{"sensor":'
            '{"x":0.25,"y":0.75,"width":0.125,"height":0.0625}}}',
      ),
    );
    var state = container.read(authenticationProvider);
    expect(state.fingerprintAvailable, isTrue);
    expect(
      state.fingerprintSensor,
      const Rect.fromLTWH(0.25, 0.75, 0.125, 0.0625),
    );
    expect(state.pinLength, 4);
    expect(state.fingerprintScanning, isFalse);

    service.emit(
      _credential(pinLength: 4, payload: '{"fingerprint":{"scanning":true}}'),
    );
    expect(container.read(authenticationProvider).fingerprintScanning, isTrue);
    service.emit(
      _credential(pinLength: 4, payload: '{"fingerprint":{"scanning":false}}'),
    );
    expect(container.read(authenticationProvider).fingerprintScanning, isFalse);

    service.emit(_credential(pinLength: 4, payload: '{"fingerprint":{}}'));
    state = container.read(authenticationProvider);
    expect(state.fingerprintReader, isTrue);
    expect(state.fingerprintAvailable, isTrue);
    expect(state.fingerprintSensor, isNull);

    // Between scans the sensor stays marked while the reader re-arms.
    service.emit(
      _credential(
        pinLength: 4,
        payload: '{"fingerprint":{"sensor":{},"ready":false}}',
      ),
    );
    state = container.read(authenticationProvider);
    expect(state.fingerprintReader, isTrue);
    expect(state.fingerprintAvailable, isFalse);

    service.emit(
      _credential(
        pinLength: 4,
        payload: '{"fingerprint":{"sensor":{"x":0.9,"y":0,"width":0.2,"height":0.1}}}',
      ),
    );
    expect(container.read(authenticationProvider).fingerprintSensor, isNull);

    service.emit(_credential(pinLength: 4));
    state = container.read(authenticationProvider);
    expect(state.fingerprintReader, isFalse);
    expect(state.fingerprintAvailable, isFalse);
    expect(state.fingerprintSensor, isNull);
  });

  testWidgets(
    'fingerprint feedback preserves password input state and expires',
    (tester) async {
      final service = _FakeAuthenticationService();
      addTearDown(service.dispose);
      final container = ProviderContainer.test(
        overrides: [authenticationServiceProvider.overrideWithValue(service)],
      );
      final controller = container.read(authenticationProvider.notifier);
      service.emit(_state(locked: true, available: true));
      service.emit(_prompt(attemptId: 17, sequence: 4, message: 'Password:'));
      final prompt = container.read(authenticationProvider).prompt;
      const rejected = AuthenticationPacket(
        kind: AuthenticationPacketKind.fingerprintFeedback,
        locked: true,
        available: true,
        busy: true,
        rateLimited: false,
        attemptId: 17,
        argument: 0,
        payload: 'no-match',
      );
      service.emit(rejected);
      expect(
        container.read(authenticationProvider).fingerprintRejected,
        isTrue,
      );
      expect(container.read(authenticationProvider).prompt, same(prompt));
      expect(container.read(authenticationProvider).busy, isTrue);
      expect(container.read(authenticationProvider).locked, isTrue);
      expect(container.read(authenticationProvider).rateLimited, isFalse);
      controller.respond('still-valid');
      expect(service.responses, ['still-valid']);
      await tester.pump(const Duration(seconds: 3));
      service.emit(rejected);
      await tester.pump(const Duration(seconds: 2));
      expect(
        container.read(authenticationProvider).fingerprintRejected,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        container.read(authenticationProvider).fingerprintRejected,
        isFalse,
      );
      service.emit(rejected);
      service.emit(
        _result(
          locked: false,
          available: true,
          attemptId: 17,
          message: '',
          success: true,
        ),
      );
      expect(
        container.read(authenticationProvider).fingerprintRejected,
        isFalse,
      );
      service.emit(rejected);
      expect(
        container.read(authenticationProvider).fingerprintRejected,
        isFalse,
      );
      expect(container.read(authenticationProvider).locked, isFalse);
    },
  );

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
  AuthenticationPromptStyle style = AuthenticationPromptStyle.echoOff,
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
    promptStyle: style,
  );
}

AuthenticationPacket _credential({
  required int pinLength,
  String payload = '',
}) {
  return AuthenticationPacket(
    kind: AuthenticationPacketKind.credential,
    locked: true,
    available: true,
    busy: false,
    rateLimited: false,
    attemptId: 0,
    argument: pinLength,
    payload: payload,
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
  int passwordBeginCount = 0;
  int synchronizeCount = 0;
  int lockCount = 0;

  @override
  Stream<AuthenticationPacket> get events => _events.stream;

  void emit(AuthenticationPacket packet) => _events.add(packet);

  @override
  void begin({bool password = false}) {
    beginCount += 1;
    if (password) passwordBeginCount += 1;
  }

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
  void offerFingerprint(bool offered) {}

  @override
  void dispose() {
    _events.close();
  }
}
