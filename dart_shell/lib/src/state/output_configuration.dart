import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/output_configuration.dart';
import '../platform/denial_bridge.dart';
import 'shell_controller.dart';

class OutputConfigurationState {
  const OutputConfigurationState({
    this.configuration,
    this.draftOutputs = const <DenialOutput>[],
    this.selectedName,
    this.loading = false,
    this.applying = false,
    this.dirty = false,
    this.error,
  });

  final DenialOutputConfiguration? configuration;
  final List<DenialOutput> draftOutputs;
  final String? selectedName;
  final bool loading;
  final bool applying;
  final bool dirty;
  final String? error;

  DenialOutput? get selectedOutput {
    for (final output in draftOutputs) {
      if (output.name == selectedName) {
        return output;
      }
    }
    return draftOutputs.firstOrNull;
  }

  OutputConfigurationState copyWith({
    DenialOutputConfiguration? configuration,
    List<DenialOutput>? draftOutputs,
    String? selectedName,
    bool? loading,
    bool? applying,
    bool? dirty,
    String? error,
    bool clearError = false,
  }) {
    return OutputConfigurationState(
      configuration: configuration ?? this.configuration,
      draftOutputs: draftOutputs ?? this.draftOutputs,
      selectedName: selectedName ?? this.selectedName,
      loading: loading ?? this.loading,
      applying: applying ?? this.applying,
      dirty: dirty ?? this.dirty,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final outputConfigurationProvider =
    NotifierProvider<OutputConfigurationController, OutputConfigurationState>(
      OutputConfigurationController.new,
    );

class OutputConfigurationController extends Notifier<OutputConfigurationState> {
  static const _confirmationTimeoutMilliseconds = 10_000;

  late DenialBridge _bridge;
  int _generation = 0;

  @override
  OutputConfigurationState build() {
    _bridge = ref.watch(denialBridgeProvider);
    final generation = ++_generation;
    ref.onDispose(() => _generation += 1);
    scheduleMicrotask(() {
      if (generation == _generation) {
        unawaited(refresh());
      }
    });
    return const OutputConfigurationState(loading: true);
  }

  Future<void> refresh() async {
    final generation = _generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final configuration = await _bridge.readOutputConfiguration();
      if (generation != _generation) {
        return;
      }
      final outputs = List<DenialOutput>.unmodifiable(configuration.outputs);
      final selected =
          outputs.any((output) => output.name == state.selectedName)
          ? state.selectedName
          : outputs.firstOrNull?.name;
      state = OutputConfigurationState(
        configuration: configuration,
        draftOutputs: outputs,
        selectedName: selected,
      );
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(
          loading: false,
          applying: false,
          error: error.toString(),
        );
      }
    }
  }

  void select(String name) {
    if (state.draftOutputs.any((output) => output.name == name)) {
      state = state.copyWith(selectedName: name);
    }
  }

  void setPosition(String name, int x, int y) {
    _replace(name, (output) => output.copyWith(x: x, y: y));
  }

  void setMode(String name, DenialOutputMode mode) {
    _replace(name, (output) => output.copyWith(currentMode: mode));
  }

  void setScale(String name, double scale) {
    if (!scale.isFinite || scale < 0.25 || scale > 8) {
      return;
    }
    _replace(name, (output) => output.copyWith(scale: scale));
  }

  void setTransform(String name, DenialOutputTransform transform) {
    _replace(name, (output) => output.copyWith(transform: transform));
  }

  void discard() {
    final configuration = state.configuration;
    if (configuration == null) {
      return;
    }
    state = state.copyWith(
      draftOutputs: List<DenialOutput>.unmodifiable(configuration.outputs),
      dirty: false,
      clearError: true,
    );
  }

  Future<bool> apply() async {
    final configuration = state.configuration;
    if (configuration == null ||
        !configuration.capabilities.apply ||
        state.applying ||
        !state.dirty) {
      return false;
    }
    final generation = _generation;
    state = state.copyWith(applying: true, clearError: true);
    try {
      final applied = await _bridge.applyOutputConfiguration(
        serial: configuration.serial,
        outputs: state.draftOutputs,
        persistent: configuration.capabilities.persistent,
        confirmationTimeoutMilliseconds: _confirmationTimeoutMilliseconds,
      );
      if (generation != _generation) {
        return true;
      }
      state = OutputConfigurationState(
        configuration: applied,
        draftOutputs: List<DenialOutput>.unmodifiable(applied.outputs),
        selectedName: state.selectedName,
      );
      return true;
    } on DenialOutputControlException catch (error) {
      if (generation == _generation) {
        state = state.copyWith(applying: false, error: error.message);
        if (error.code == 'stale_configuration') {
          unawaited(refresh());
        }
      }
      return false;
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(applying: false, error: error.toString());
      }
      return false;
    }
  }

  Future<bool> keepChanges() => _finishConfirmation(keep: true);

  Future<bool> rollbackChanges() => _finishConfirmation(keep: false);

  Future<bool> _finishConfirmation({required bool keep}) async {
    final confirmation = state.configuration?.pendingConfirmation;
    if (confirmation == null || state.applying) {
      return false;
    }
    final generation = _generation;
    state = state.copyWith(applying: true, clearError: true);
    try {
      if (keep) {
        await _bridge.confirmOutputConfiguration(confirmation.token);
      } else {
        await _bridge.rollbackOutputConfiguration(confirmation.token);
      }
      if (generation == _generation) {
        await refresh();
      }
      return true;
    } on DenialOutputControlException catch (error) {
      if (generation == _generation) {
        state = state.copyWith(applying: false, error: error.message);
      }
      return false;
    } on Object catch (error) {
      if (generation == _generation) {
        state = state.copyWith(applying: false, error: error.toString());
      }
      return false;
    }
  }

  void _replace(
    String name,
    DenialOutput Function(DenialOutput output) update,
  ) {
    var found = false;
    final outputs = state.draftOutputs
        .map((output) {
          if (output.name != name) {
            return output;
          }
          found = true;
          return update(output);
        })
        .toList(growable: false);
    if (found) {
      state = state.copyWith(
        draftOutputs: List<DenialOutput>.unmodifiable(outputs),
        dirty: true,
        clearError: true,
      );
    }
  }
}
