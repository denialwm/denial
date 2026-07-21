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
    required this.refreshing,
    required this.systemChanging,
    required this.pboChanging,
    this.error,
  });

  factory DesktopPowerModesState.initial() => const DesktopPowerModesState(
    systemAvailable: false,
    systemProfile: PowerProfile.balanced,
    pboAvailable: false,
    pboProfile: null,
    refreshing: false,
    systemChanging: false,
    pboChanging: false,
  );

  final bool systemAvailable;
  final String systemProfile;
  final bool pboAvailable;
  final String? pboProfile;
  final bool refreshing;
  final bool systemChanging;
  final bool pboChanging;
  final String? error;

  DesktopPowerModesState copyWith({
    bool? systemAvailable,
    String? systemProfile,
    bool? pboAvailable,
    String? pboProfile,
    bool clearPboProfile = false,
    bool? refreshing,
    bool? systemChanging,
    bool? pboChanging,
    String? error,
    bool clearError = false,
  }) {
    return DesktopPowerModesState(
      systemAvailable: systemAvailable ?? this.systemAvailable,
      systemProfile: systemProfile ?? this.systemProfile,
      pboAvailable: pboAvailable ?? this.pboAvailable,
      pboProfile: clearPboProfile ? null : pboProfile ?? this.pboProfile,
      refreshing: refreshing ?? this.refreshing,
      systemChanging: systemChanging ?? this.systemChanging,
      pboChanging: pboChanging ?? this.pboChanging,
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
  @override
  DesktopPowerModesState build() {
    _service = ref.watch(desktopPowerModesServiceProvider);
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

  Future<void> refresh() async {
    if (state.refreshing) {
      return;
    }
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
