import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/desktop_power_modes_service.dart';
import '../services/power_profile_service.dart';
import 'notifier_lifecycle.dart';

@immutable
class DesktopPowerModesState {
  const DesktopPowerModesState({
    required this.systemAvailable,
    required this.systemProfile,
    required this.pboAvailable,
    required this.pboProfile,
    required this.gpuAvailable,
    required this.gpuPerformancePreset,
    required this.refreshing,
    required this.systemChanging,
    required this.pboChanging,
    required this.gpuChanging,
    this.error,
  });

  factory DesktopPowerModesState.initial() => const DesktopPowerModesState(
    systemAvailable: false,
    systemProfile: PowerProfile.balanced,
    pboAvailable: false,
    pboProfile: null,
    gpuAvailable: false,
    gpuPerformancePreset: null,
    refreshing: false,
    systemChanging: false,
    pboChanging: false,
    gpuChanging: false,
  );

  final bool systemAvailable;
  final String systemProfile;
  final bool pboAvailable;
  final String? pboProfile;
  final bool gpuAvailable;
  final String? gpuPerformancePreset;
  final bool refreshing;
  final bool systemChanging;
  final bool pboChanging;
  final bool gpuChanging;
  final String? error;

  DesktopPowerModesState copyWith({
    bool? systemAvailable,
    String? systemProfile,
    bool? pboAvailable,
    String? pboProfile,
    bool clearPboProfile = false,
    bool? gpuAvailable,
    String? gpuPerformancePreset,
    bool clearGpuPerformancePreset = false,
    bool? refreshing,
    bool? systemChanging,
    bool? pboChanging,
    bool? gpuChanging,
    String? error,
    bool clearError = false,
  }) {
    return DesktopPowerModesState(
      systemAvailable: systemAvailable ?? this.systemAvailable,
      systemProfile: systemProfile ?? this.systemProfile,
      pboAvailable: pboAvailable ?? this.pboAvailable,
      pboProfile: clearPboProfile ? null : pboProfile ?? this.pboProfile,
      gpuAvailable: gpuAvailable ?? this.gpuAvailable,
      gpuPerformancePreset: clearGpuPerformancePreset
          ? null
          : gpuPerformancePreset ?? this.gpuPerformancePreset,
      refreshing: refreshing ?? this.refreshing,
      systemChanging: systemChanging ?? this.systemChanging,
      pboChanging: pboChanging ?? this.pboChanging,
      gpuChanging: gpuChanging ?? this.gpuChanging,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final desktopPowerModesProvider =
    NotifierProvider<DesktopPowerModesController, DesktopPowerModesState>(
      DesktopPowerModesController.new,
    );

class DesktopPowerModesController extends Notifier<DesktopPowerModesState>
    with NotifierLifecycle<DesktopPowerModesState> {
  static const Duration _automaticRefreshInterval = Duration(seconds: 30);

  @override
  DesktopPowerModesState build() {
    _service = ref.watch(desktopPowerModesServiceProvider);
    _lastRefreshAttemptAge = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        unawaited(refresh());
      }
    });
    return DesktopPowerModesState.initial();
  }

  late DesktopPowerModesService _service;
  late int _buildGeneration;
  Stopwatch? _lastRefreshAttemptAge;

  Future<void> refreshIfStale() {
    final lastRefreshAttemptAge = _lastRefreshAttemptAge;
    if (lastRefreshAttemptAge != null &&
        lastRefreshAttemptAge.elapsed < _automaticRefreshInterval) {
      return Future<void>.value();
    }
    return refresh();
  }

  Future<void> refresh() async {
    if (state.refreshing) {
      return;
    }
    _lastRefreshAttemptAge = Stopwatch()..start();
    final generation = _buildGeneration;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      final snapshot = await _service.readSnapshot();
      if (!isBuildGenerationActive(generation)) {
        return;
      }
      state = state.copyWith(
        systemAvailable: snapshot.systemAvailable,
        systemProfile: snapshot.systemProfile,
        pboAvailable: snapshot.pboAvailable,
        pboProfile: snapshot.pboProfile,
        clearPboProfile: snapshot.pboProfile == null,
        gpuAvailable: snapshot.gpuAvailable,
        gpuPerformancePreset: snapshot.gpuPerformancePreset,
        clearGpuPerformancePreset: snapshot.gpuPerformancePreset == null,
        refreshing: false,
        clearError: true,
      );
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(refreshing: false, error: _message(error));
      }
    }
  }

  Future<void> selectSystemProfile(String profile) async {
    if (state.systemChanging || !state.systemAvailable) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(systemChanging: true, clearError: true);
    try {
      await _service.applySystemProfile(profile);
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          systemProfile: profile,
          systemChanging: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(systemChanging: false, error: _message(error));
      }
    }
  }

  Future<void> selectPboProfile(String profile) async {
    if (state.pboChanging || !state.pboAvailable) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(pboChanging: true, clearError: true);
    try {
      await _service.applyPboProfile(profile);
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          pboProfile: profile,
          pboChanging: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(pboChanging: false, error: _message(error));
      }
    }
  }

  Future<void> selectGpuPerformancePreset(String preset) async {
    if (state.gpuChanging || !state.gpuAvailable) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(gpuChanging: true, clearError: true);
    try {
      await _service.applyGpuPerformancePreset(preset);
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(
          gpuPerformancePreset: preset,
          gpuChanging: false,
          clearError: true,
        );
      }
    } on Object catch (error) {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(gpuChanging: false, error: _message(error));
      }
    }
  }

  String _message(Object error) {
    final text = error.toString();
    if (text.startsWith('Bad state: ')) {
      return text.substring(11);
    }
    if (error is FileSystemException) {
      return error.message;
    }
    return text;
  }
}
