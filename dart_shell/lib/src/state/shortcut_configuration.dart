import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shortcut_configuration.dart';
import '../platform/denial_bridge.dart';
import 'shell_controller.dart';

class ShortcutConfigurationState {
  const ShortcutConfigurationState({
    this.configuration,
    this.loading = true,
    this.saving = false,
    this.deletingShortcut,
    this.error,
  });

  final DenialShortcutConfiguration? configuration;
  final bool loading;
  final bool saving;
  final String? deletingShortcut;
  final String? error;

  bool get busy => saving || deletingShortcut != null;

  ShortcutConfigurationState copyWith({
    DenialShortcutConfiguration? configuration,
    bool? loading,
    bool? saving,
    String? deletingShortcut,
    String? error,
    bool clearDeletingShortcut = false,
    bool clearError = false,
  }) {
    return ShortcutConfigurationState(
      configuration: configuration ?? this.configuration,
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      deletingShortcut: clearDeletingShortcut
          ? null
          : deletingShortcut ?? this.deletingShortcut,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final shortcutConfigurationProvider =
    NotifierProvider<
      ShortcutConfigurationController,
      ShortcutConfigurationState
    >(ShortcutConfigurationController.new);

class ShortcutConfigurationController
    extends Notifier<ShortcutConfigurationState> {
  late DenialBridge _bridge;
  StreamSubscription<DenialShortcutConfiguration>? _subscription;
  int _generation = 0;

  @override
  ShortcutConfigurationState build() {
    _bridge = ref.watch(denialBridgeProvider);
    _subscription?.cancel();
    final generation = ++_generation;
    _subscription = _bridge.shortcutConfigurations.listen((configuration) {
      if (generation == _generation) {
        _applyConfiguration(configuration);
      }
    });
    ref.onDispose(() {
      _generation += 1;
      unawaited(_subscription?.cancel());
      _subscription = null;
    });
    scheduleMicrotask(() => unawaited(refresh()));
    return const ShortcutConfigurationState();
  }

  Future<void> refresh() async {
    final generation = _generation;
    if (state.configuration == null) {
      state = state.copyWith(loading: true, clearError: true);
    }
    try {
      final configuration = await _bridge.readShortcutConfiguration();
      if (generation == _generation) {
        _applyConfiguration(configuration);
      }
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(
          loading: false,
          error: error.toString(),
          clearDeletingShortcut: true,
        );
      }
    }
  }

  Future<bool> removeShortcut(String shortcut) async {
    final configuration = state.configuration;
    if (configuration == null || state.busy) {
      return false;
    }
    state = state.copyWith(deletingShortcut: shortcut, clearError: true);
    try {
      DenialShortcutConfiguration applied;
      try {
        applied = await _bridge.removeShortcut(
          expectedRevision: configuration.revision,
          shortcut: shortcut,
        );
      } on StateError {
        final latest = await _bridge.readShortcutConfiguration();
        final stillExists = latest.shortcuts.any(
          (binding) => binding.shortcut == shortcut,
        );
        if (!stillExists) {
          applied = latest;
        } else {
          if (latest.revision == configuration.revision) {
            rethrow;
          }
          applied = await _bridge.removeShortcut(
            expectedRevision: latest.revision,
            shortcut: shortcut,
          );
        }
      }
      _applyConfiguration(applied);
      return true;
    } on Object catch (error) {
      state = state.copyWith(
        loading: false,
        error: error.toString(),
        clearDeletingShortcut: true,
      );
      return false;
    }
  }

  Future<DenialShortcutValidation> validateShortcut({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) {
    return _bridge.validateShortcut(
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
  }

  Future<bool> addShortcut(DenialShortcutBinding shortcut) {
    return _saveShortcut(shortcut: shortcut);
  }

  Future<bool> updateShortcut({
    required String existingShortcut,
    required DenialShortcutBinding shortcut,
  }) {
    return _saveShortcut(
      shortcut: shortcut,
      existingShortcut: existingShortcut,
    );
  }

  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  Future<bool> _saveShortcut({
    required DenialShortcutBinding shortcut,
    String? existingShortcut,
  }) async {
    final configuration = state.configuration;
    if (configuration == null || state.busy) {
      return false;
    }
    state = state.copyWith(saving: true, clearError: true);
    try {
      DenialShortcutConfiguration applied;
      try {
        applied = await _sendSave(
          configuration: configuration,
          shortcut: shortcut,
          existingShortcut: existingShortcut,
        );
      } on StateError {
        final latest = await _bridge.readShortcutConfiguration();
        if (latest.revision == configuration.revision) {
          rethrow;
        }
        applied = await _sendSave(
          configuration: latest,
          shortcut: shortcut,
          existingShortcut: existingShortcut,
        );
      }
      _applyConfiguration(applied);
      state = state.copyWith(saving: false, clearError: true);
      return true;
    } on Object catch (error) {
      state = state.copyWith(
        loading: false,
        saving: false,
        error: error.toString(),
      );
      return false;
    }
  }

  Future<DenialShortcutConfiguration> _sendSave({
    required DenialShortcutConfiguration configuration,
    required DenialShortcutBinding shortcut,
    required String? existingShortcut,
  }) {
    if (existingShortcut == null) {
      return _bridge.addShortcut(
        expectedRevision: configuration.revision,
        shortcut: shortcut,
      );
    }
    return _bridge.updateShortcut(
      expectedRevision: configuration.revision,
      existingShortcut: existingShortcut,
      shortcut: shortcut,
    );
  }

  void _applyConfiguration(DenialShortcutConfiguration configuration) {
    if (identical(state.configuration, configuration) &&
        !state.loading &&
        !state.saving &&
        state.error == null &&
        state.deletingShortcut == null) {
      return;
    }
    final deletingShortcut = state.deletingShortcut;
    final deletionCompleted =
        deletingShortcut != null &&
        !configuration.shortcuts.any(
          (binding) => binding.shortcut == deletingShortcut,
        );
    state = state.copyWith(
      configuration: configuration,
      loading: false,
      clearDeletingShortcut: deletionCompleted,
      clearError: true,
    );
  }
}
