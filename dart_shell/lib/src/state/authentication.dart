import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/authentication_protocol.dart';
import '../services/authentication_service.dart';
import 'notifier_lifecycle.dart';

final authenticationServiceProvider = Provider<AuthenticationService>((ref) {
  final service = NativeAuthenticationService();
  ref.onDispose(service.dispose);
  return service;
});

final authenticationProvider =
    NotifierProvider<AuthenticationController, AuthenticationState>(
      AuthenticationController.new,
    );

@immutable
class AuthenticationPrompt {
  const AuthenticationPrompt({
    required this.attemptId,
    required this.sequence,
    required this.style,
    required this.message,
  });

  final int attemptId;
  final int sequence;
  final AuthenticationPromptStyle style;
  final String message;

  bool get requiresResponse => style.requiresResponse;
  bool get obscure => style == AuthenticationPromptStyle.echoOff;
}

@immutable
class AuthenticationState {
  const AuthenticationState({
    required this.synchronized,
    required this.locked,
    required this.available,
    required this.busy,
    required this.attemptId,
    required this.cooldown,
    required this.statusMessage,
    required this.prompt,
    required this.resultMessage,
    required this.resultIsError,
  });

  const AuthenticationState.initial()
    : synchronized = false,
      locked = false,
      available = false,
      busy = false,
      attemptId = 0,
      cooldown = Duration.zero,
      statusMessage = null,
      prompt = null,
      resultMessage = null,
      resultIsError = false;

  final bool synchronized;
  final bool locked;
  final bool available;
  final bool busy;
  final int attemptId;
  final Duration cooldown;
  final String? statusMessage;
  final AuthenticationPrompt? prompt;
  final String? resultMessage;
  final bool resultIsError;

  bool get rateLimited => cooldown > Duration.zero;

  AuthenticationState copyWith({
    bool? synchronized,
    bool? locked,
    bool? available,
    bool? busy,
    int? attemptId,
    Duration? cooldown,
    String? statusMessage,
    bool clearStatusMessage = false,
    AuthenticationPrompt? prompt,
    bool clearPrompt = false,
    String? resultMessage,
    bool clearResultMessage = false,
    bool? resultIsError,
  }) {
    return AuthenticationState(
      synchronized: synchronized ?? this.synchronized,
      locked: locked ?? this.locked,
      available: available ?? this.available,
      busy: busy ?? this.busy,
      attemptId: attemptId ?? this.attemptId,
      cooldown: cooldown ?? this.cooldown,
      statusMessage: clearStatusMessage
          ? null
          : (statusMessage ?? this.statusMessage),
      prompt: clearPrompt ? null : (prompt ?? this.prompt),
      resultMessage: clearResultMessage
          ? null
          : (resultMessage ?? this.resultMessage),
      resultIsError: resultIsError ?? this.resultIsError,
    );
  }
}

class AuthenticationController extends Notifier<AuthenticationState>
    with NotifierLifecycle<AuthenticationState> {
  @override
  AuthenticationState build() {
    _service = ref.watch(authenticationServiceProvider);
    _cooldownTimer = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _service.events.listen(
      (packet) => _handleEvent(packet, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      _cooldownTimer?.cancel();
      _cooldownTimer = null;
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        _service.synchronize();
      }
    });
    return const AuthenticationState.initial();
  }

  late AuthenticationService _service;
  late int _buildGeneration;
  Timer? _cooldownTimer;

  void lock() => _service.lock();

  void begin() {
    if (!state.locked || !state.available || state.busy || state.rateLimited) {
      return;
    }
    state = state.copyWith(clearResultMessage: true);
    _service.begin();
  }

  void respond(String response) {
    final prompt = state.prompt;
    if (prompt == null || !prompt.requiresResponse || !state.busy) {
      return;
    }
    state = state.copyWith(clearResultMessage: true);
    _service.respond(
      attemptId: prompt.attemptId,
      promptSequence: prompt.sequence,
      response: response,
    );
  }

  void cancel() {
    if (!state.busy || state.attemptId == 0) {
      return;
    }
    _service.cancel(attemptId: state.attemptId);
  }

  void clearResult() {
    state = state.copyWith(clearResultMessage: true);
  }

  void _handleEvent(AuthenticationPacket packet, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final cooldown = Duration(
      milliseconds: packet.kind == AuthenticationPacketKind.prompt
          ? 0
          : packet.argument,
    );
    AuthenticationPrompt? prompt = state.prompt;
    var clearPrompt = !packet.busy || packet.attemptId != state.attemptId;
    String? resultMessage = state.resultMessage;
    var clearResult = false;
    var resultIsError = state.resultIsError;

    if (packet.kind == AuthenticationPacketKind.prompt) {
      prompt = AuthenticationPrompt(
        attemptId: packet.attemptId,
        sequence: packet.argument,
        style: packet.promptStyle!,
        message: packet.payload,
      );
      clearPrompt = false;
      if (packet.promptStyle == AuthenticationPromptStyle.error) {
        resultMessage = packet.payload;
        resultIsError = true;
      }
    } else if (packet.kind == AuthenticationPacketKind.result) {
      clearPrompt = true;
      resultMessage = packet.cancelled ? null : packet.payload;
      clearResult = packet.cancelled || packet.success;
      resultIsError = !packet.success && !packet.cancelled;
    }

    state = state.copyWith(
      synchronized: true,
      locked: packet.locked,
      available: packet.available,
      busy: packet.busy,
      attemptId: packet.attemptId,
      cooldown: cooldown,
      statusMessage:
          packet.payload.isNotEmpty &&
              packet.kind == AuthenticationPacketKind.state
          ? packet.payload
          : null,
      clearStatusMessage:
          packet.kind != AuthenticationPacketKind.state ||
          packet.payload.isEmpty,
      prompt: prompt,
      clearPrompt: clearPrompt,
      resultMessage: resultMessage,
      clearResultMessage: clearResult,
      resultIsError: resultIsError,
    );
    _scheduleCooldownSync(cooldown);
  }

  void _scheduleCooldownSync(Duration cooldown) {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    if (cooldown <= Duration.zero) {
      return;
    }
    final generation = _buildGeneration;
    _cooldownTimer = Timer(cooldown + const Duration(milliseconds: 20), () {
      if (isBuildGenerationActive(generation)) {
        _service.synchronize();
      }
    });
  }
}
