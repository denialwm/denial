import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import '../platform/denial_bridge_provider.dart';

/// Native automatic-orientation policy. A lock freezes the applied device
/// rotation; explicit per-output rotation remains available while locked.
class RotationLockState {
  const RotationLockState({
    this.supported = false,
    this.locked = false,
    this.busy = false,
    this.error,
  });

  final bool supported;
  final bool locked;
  final bool busy;
  final Object? error;
}

final rotationLockProvider =
    NotifierProvider<RotationLockController, RotationLockState>(
      RotationLockController.new,
    );

class RotationLockController extends Notifier<RotationLockState> {
  int _revision = 0;
  int _generation = 0;
  bool _busy = false;

  @override
  RotationLockState build() {
    final bridge = ref.watch(denialBridgeProvider);
    final generation = ++_generation;
    _revision = 0;
    _busy = false;
    final subscription = bridge.settingsDocuments.listen(
      (document) => _accept(document, generation),
      onError: (Object error) {
        if (ref.mounted && generation == _generation) {
          state = RotationLockState(
            supported: state.supported,
            locked: state.locked,
            busy: _busy,
            error: error,
          );
        }
      },
    );
    ref.onDispose(subscription.cancel);
    // Also seed when another settings consumer already owns the broadcast
    // subscription (broadcast streams do not replay their initial snapshot).
    scheduleMicrotask(() async {
      try {
        _accept(await bridge.readSettingsDocument(), generation);
      } on Object catch (error) {
        if (ref.mounted && generation == _generation && _revision == 0) {
          state = RotationLockState(
            supported: state.supported,
            locked: state.locked,
            busy: _busy,
            error: error,
          );
        }
      }
    });
    return const RotationLockState();
  }

  void _accept(DenialSettingsDocument document, int generation) {
    if (!ref.mounted ||
        generation != _generation ||
        document.revision < _revision) {
      return;
    }
    final json = jsonDecode(document.json) as Map<String, dynamic>;
    final policy = json['rotationLock'];
    _revision = document.revision;
    state = RotationLockState(
      supported: json['rotationLockSupported'] == true,
      locked: policy is Map && policy['enabled'] == true,
      busy: _busy,
    );
  }

  /// No optimistic "locked" state: only the native committed response or
  /// subscription may change the lock indicator. Failure preserves that state.
  Future<void> toggle() async {
    if (!state.supported || _busy) return;
    final enabled = !state.locked;
    final generation = _generation;
    final bridge = ref.read(denialBridgeProvider);
    _busy = true;
    state = RotationLockState(
      supported: state.supported,
      locked: state.locked,
      busy: true,
    );
    Object? failure;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final document = await bridge.readSettingsDocument();
        if (!ref.mounted || generation != _generation) return;
        final json = jsonDecode(document.json) as Map<String, dynamic>;
        if (json['rotationLockSupported'] != true) {
          _accept(document, generation);
          return;
        }
        json['rotationLock'] = {'enabled': enabled};
        try {
          final response = await bridge.writeSettingsDocument(
            expectedRevision: document.revision,
            document: jsonEncode(json),
          );
          _accept(response, generation);
          break;
        } on StateError {
          if (attempt == 1) rethrow;
          // Re-read and merge just this policy, preserving concurrent settings.
        }
      }
    } on Object catch (error) {
      failure = error;
    } finally {
      if (ref.mounted && generation == _generation) {
        _busy = false;
        state = RotationLockState(
          supported: state.supported,
          locked: state.locked,
          error: failure,
        );
      }
    }
  }
}
