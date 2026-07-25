import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../platform/denial_bridge.dart';
import '../services/brightness_service.dart';
import 'display_layout.dart';
import 'notifier_lifecycle.dart';

final displayBrightnessProvider =
    NotifierProvider<DisplayBrightnessController, DisplayBrightnessState>(
      DisplayBrightnessController.new,
    );

class DisplayBrightnessState {
  const DisplayBrightnessState({
    required this.levels,
    required this.loading,
  });

  final Map<int, double> levels;
  final Set<int> loading;

  DisplayBrightnessState copyWith({
    Map<int, double>? levels,
    Set<int>? loading,
  }) {
    return DisplayBrightnessState(
      levels: levels ?? this.levels,
      loading: loading ?? this.loading,
    );
  }
}

class DisplayBrightnessController extends Notifier<DisplayBrightnessState>
    with NotifierLifecycle<DisplayBrightnessState> {
  static const Duration _commitInterval = Duration(milliseconds: 90);

  final Map<int, Timer> _commitTimers = <int, Timer>{};
  late BrightnessService _service;
  late List<DisplayOutput> _outputs;
  late int _buildGeneration;

  @override
  DisplayBrightnessState build() {
    _service = ref.watch(brightnessServiceProvider);
    _outputs = List<DisplayOutput>.unmodifiable(
      ref.watch(displayLayoutProvider)?.outputs ?? const <DisplayOutput>[],
    );
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _service.states.listen(
      (update) => _handleNativeUpdate(update, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      for (final timer in _commitTimers.values) {
        timer.cancel();
      }
      _commitTimers.clear();
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        for (final output in _outputs) {
          unawaited(_refreshOutput(output, generation));
        }
      }
    });
    return DisplayBrightnessState(
      levels: Map<int, double>.unmodifiable({
        for (final output in _outputs) output.monitorId: 0.72,
      }),
      loading: Set<int>.unmodifiable({
        for (final output in _outputs) output.monitorId,
      }),
    );
  }

  void setLevel(DisplayOutput output, double value) {
    _recordLevel(output, value);
    _commitTimers[output.monitorId] ??= Timer(
      _commitInterval,
      () => _flush(output),
    );
  }

  void commitLevel(DisplayOutput output, double value) {
    _recordLevel(output, value);
    _commitTimers.remove(output.monitorId)?.cancel();
    _flush(output);
  }

  void reset() {
    for (final output in _outputs) {
      commitLevel(output, 0.72);
    }
  }

  void _recordLevel(DisplayOutput output, double value) {
    if (!_outputs.any((candidate) => candidate.monitorId == output.monitorId)) {
      return;
    }
    final levels = Map<int, double>.of(state.levels)
      ..[output.monitorId] = value.clamp(0.01, 1.0).toDouble();
    state = state.copyWith(levels: Map<int, double>.unmodifiable(levels));
  }

  void _flush(DisplayOutput output) {
    _commitTimers.remove(output.monitorId)?.cancel();
    final level = state.levels[output.monitorId];
    if (level == null) {
      return;
    }
    unawaited(_service.apply((level * 100).round(), output));
  }

  Future<void> _refreshOutput(
    DisplayOutput output,
    int generation,
  ) async {
    final level = await _service.readLevel(output);
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final loading = Set<int>.of(state.loading)..remove(output.monitorId);
    final levels = Map<int, double>.of(state.levels);
    if (level != null) {
      levels[output.monitorId] = level;
    }
    state = DisplayBrightnessState(
      levels: Map<int, double>.unmodifiable(levels),
      loading: Set<int>.unmodifiable(loading),
    );
  }

  void _handleNativeUpdate(
    DenialBrightnessState update,
    int generation,
  ) {
    if (!isBuildGenerationActive(generation) ||
        !state.levels.containsKey(update.monitorId)) {
      return;
    }
    final levels = Map<int, double>.of(state.levels)
      ..[update.monitorId] = update.level.clamp(0.01, 1.0).toDouble();
    final loading = Set<int>.of(state.loading)..remove(update.monitorId);
    state = DisplayBrightnessState(
      levels: Map<int, double>.unmodifiable(levels),
      loading: Set<int>.unmodifiable(loading),
    );
  }
}
