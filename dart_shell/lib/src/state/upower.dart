import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/upower_service.dart';
import 'notifier_lifecycle.dart';

@immutable
class UPowerState {
  UPowerState({
    required this.snapshot,
    required this.loading,
    required this.refreshing,
    required Set<String> changingThresholds,
    this.error,
  }) : changingThresholds = Set<String>.unmodifiable(changingThresholds);

  const UPowerState._({
    required this.snapshot,
    required this.loading,
    required this.refreshing,
    required this.changingThresholds,
    required this.error,
  });

  factory UPowerState.initial() => const UPowerState._(
    snapshot: null,
    loading: true,
    refreshing: false,
    changingThresholds: <String>{},
    error: null,
  );

  final UPowerSnapshot? snapshot;
  final bool loading;
  final bool refreshing;
  final Set<String> changingThresholds;
  final String? error;

  UPowerState copyWith({
    UPowerSnapshot? snapshot,
    bool? loading,
    bool? refreshing,
    Set<String>? changingThresholds,
    String? error,
    bool clearError = false,
  }) {
    return UPowerState._(
      snapshot: snapshot ?? this.snapshot,
      loading: loading ?? this.loading,
      refreshing: refreshing ?? this.refreshing,
      changingThresholds: changingThresholds == null
          ? this.changingThresholds
          : Set<String>.unmodifiable(changingThresholds),
      error: clearError ? null : error ?? this.error,
    );
  }
}

final upowerProvider = NotifierProvider<UPowerController, UPowerState>(
  UPowerController.new,
  isAutoDispose: true,
);

class UPowerController extends Notifier<UPowerState>
    with NotifierLifecycle<UPowerState> {
  @override
  UPowerState build() {
    _service = ref.watch(upowerServiceProvider);
    _buildGeneration = beginBuildGeneration();
    _reading = false;
    final generation = _buildGeneration;
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        unawaited(_read(generation, showRefresh: false));
      }
    });
    return UPowerState.initial();
  }

  late UPowerBackend _service;
  late int _buildGeneration;
  bool _reading = false;

  Future<void> refresh() => _read(_buildGeneration, showRefresh: true);

  Future<void> _read(int generation, {required bool showRefresh}) async {
    if (_reading || !isBuildGenerationActive(generation)) {
      return;
    }
    _reading = true;
    if (showRefresh) {
      state = state.copyWith(refreshing: true, clearError: true);
    }
    try {
      final snapshot = await _service.readSnapshot();
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          snapshot: snapshot,
          loading: false,
          refreshing: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          loading: false,
          refreshing: false,
          error: _message(error),
        );
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> setChargeThresholdEnabled(
    UPowerBattery battery,
    bool enabled,
  ) async {
    final path = battery.objectPath;
    if (!battery.chargeThresholdSupported ||
        state.changingThresholds.contains(path)) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(
      changingThresholds: <String>{...state.changingThresholds, path},
      clearError: true,
    );
    try {
      await _service.setChargeThresholdEnabled(path, enabled);
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          snapshot: state.snapshot?.withChargeThresholdEnabled(path, enabled),
          changingThresholds: <String>{
            ...state.changingThresholds.where((item) => item != path),
          },
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          changingThresholds: <String>{
            ...state.changingThresholds.where((item) => item != path),
          },
          error: _message(error),
        );
      }
    }
  }

  String _message(Object error) {
    final text = error.toString();
    return text.startsWith('Bad state: ') ? text.substring(11) : text;
  }
}
