import 'dart:async';

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final inputDeckProvider =
    NotifierProvider<InputDeckController, InputDeckSnapshot>(
      InputDeckController.new,
    );

class InputDeckController extends Notifier<InputDeckSnapshot> {
  String? _requested;
  var _disposed = false;
  var _configured = false;

  @override
  InputDeckSnapshot build() {
    _disposed = false;
    _configured = false;
    final bridge = ref.watch(denialBridgeProvider);
    final timer = bridge.useControlSocket
        ? Timer.periodic(
            const Duration(seconds: 3),
            (_) => bridge.readInputDeck(),
          )
        : null;
    final subscription = bridge.inputDeckStates.listen((snapshot) {
      state = snapshot;
      _reconcile(snapshot);
    });
    ref.listen(
      shellSettingsProvider.select((settings) => settings.inputDeck),
      (_, _) => _reconcile(state),
    );
    ref.onDispose(() {
      _disposed = true;
      timer?.cancel();
      unawaited(subscription.cancel());
      bridge.releaseInputDeck();
      bridge.configureInputDeck(null);
    });
    scheduleMicrotask(() {
      if (!_disposed) bridge.readInputDeck();
    });
    return const InputDeckSnapshot();
  }

  void _reconcile(InputDeckSnapshot snapshot) {
    final preferences = ref.read(shellSettingsProvider).inputDeck;
    final output = preferences.desiredOutput(
      touchOutputs: snapshot.touchOutputs,
      available: snapshot.available,
      locked: snapshot.locked,
    );
    if (_configured && output == _requested) return;
    _configured = true;
    _requested = output;
    ref.read(denialBridgeProvider).configureInputDeck(output);
  }

  void stop() {
    final settings = ref.read(shellSettingsProvider).inputDeck;
    ref.read(denialBridgeProvider).releaseInputDeck();
    ref
        .read(shellSettingsProvider.notifier)
        .setInputDeck(settings.copyWith(enabled: false));
  }
}
