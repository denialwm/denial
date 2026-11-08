import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'package:denial_flutter_sdk/lifecycle.dart' show NotifierLifecycle;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/system_services.dart';

import 'system_level_hud.dart';

/// Immutable state for the quick-settings shade controls.
@immutable
class QuickSettingsState {
  const QuickSettingsState({
    required this.volume,
    required this.profile,
    required this.screenshotRunning,
  });

  factory QuickSettingsState.initial() => const QuickSettingsState(
    volume: 0.46,
    profile: PowerProfile.balanced,
    screenshotRunning: false,
  );

  final double volume;
  final String profile;
  final bool screenshotRunning;

  QuickSettingsState copyWith({
    double? volume,
    String? profile,
    bool? screenshotRunning,
  }) {
    return QuickSettingsState(
      volume: volume ?? this.volume,
      profile: profile ?? this.profile,
      screenshotRunning: screenshotRunning ?? this.screenshotRunning,
    );
  }
}

final quickSettingsProvider =
    NotifierProvider<QuickSettingsController, QuickSettingsState>(
      QuickSettingsController.new,
    );

/// Owns volume interaction, power-profile selection, and one-shot action guards.
/// Brightness, connectivity, and DND use their shared signal-driven providers.
class QuickSettingsController extends Notifier<QuickSettingsState>
    with NotifierLifecycle<QuickSettingsState> {
  @override
  QuickSettingsState build() {
    _audio = ref.watch(audioServiceProvider);
    _audioHudSuppression = ref.watch(systemLevelHudAudioSuppressionProvider);
    _power = ref.watch(powerProfileServiceProvider);
    _actions = ref.watch(systemActionsServiceProvider);
    _volumeTimer = null;
    _volumeAcknowledgementTimer = null;
    _pendingVolume = -1;
    _pendingVolumeSerial = 0;
    _nextVolumeRequestSerial = 1;
    _latestDesiredVolumeSerial = 0;
    _latestDesiredVolumePercent = -1;
    _observedVolumePercent = -1;
    _volumeInteracting = false;
    _deferredAudioState = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _audio.states.listen(
      (update) => _handleAudioState(update, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      _volumeTimer?.cancel();
      _volumeAcknowledgementTimer?.cancel();
      _volumeTimer = null;
      _volumeAcknowledgementTimer = null;
    });
    scheduleMicrotask(() {
      if (isBuildGenerationActive(generation)) {
        unawaited(_loadInitial(generation));
      }
    });
    return QuickSettingsState.initial();
  }

  static const Duration _volumeCommitInterval = Duration(milliseconds: 90);
  static const Duration _volumeAcknowledgementTimeout = Duration(seconds: 2);
  static const Duration _screenshotSettleDelay = Duration(milliseconds: 260);

  late AudioService _audio;
  late SystemLevelHudAudioSuppression _audioHudSuppression;
  late PowerProfileService _power;
  late SystemActionsService _actions;
  late int _buildGeneration;

  Timer? _volumeTimer;
  Timer? _volumeAcknowledgementTimer;
  int _pendingVolume = -1;
  int _pendingVolumeSerial = 0;
  int _nextVolumeRequestSerial = 1;
  int _latestDesiredVolumeSerial = 0;
  int _latestDesiredVolumePercent = -1;
  int _observedVolumePercent = -1;
  bool _volumeInteracting = false;
  AudioLevelState? _deferredAudioState;

  Future<void> _loadInitial(int generation) async {
    await Future.wait<void>(<Future<void>>[
      _loadInitialVolume(generation),
      _loadInitialPowerProfile(generation),
    ]);
  }

  Future<void> _loadInitialVolume(int generation) async {
    final volume = await _audio.readLevel();
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    if (volume != null) {
      _handleAudioState(
        AudioLevelState(level: volume, requestSerial: 0),
        generation,
      );
    }
  }

  /// Re-reads the default sink after an output switch: devices carry their
  /// own level and the worker's push may describe the old sink.
  Future<void> refreshVolume() async {
    final level = await _audio.readLevel();
    if (level == null) return;
    _handleAudioState(
      AudioLevelState(level: level, requestSerial: 0),
      _buildGeneration,
    );
  }

  Future<void> _loadInitialPowerProfile(int generation) async {
    final profile = await _power.read();
    if (isBuildGenerationActive(generation) && profile != null) {
      state = state.copyWith(profile: profile);
    }
  }

  void beginVolumeInteraction() {
    _volumeInteracting = true;
    _deferredAudioState = null;
  }

  void setVolume(double value) {
    _recordVolumeIntent(value);
    _scheduleVolumeApply();
  }

  void setDashboardVolume(double value) {
    _recordVolumeIntent(value, suppressHud: true);
    _scheduleVolumeApply();
  }

  void commitVolume(double value) {
    _recordVolumeIntent(value, force: true);
    _volumeInteracting = false;
    _scheduleVolumeApply(immediate: true);
    _applyDeferredAudioStateIfIdle();
  }

  void commitDashboardVolume(double value) {
    _recordVolumeIntent(value, force: true, suppressHud: true);
    _volumeInteracting = false;
    _scheduleVolumeApply(immediate: true);
    _applyDeferredAudioStateIfIdle();
  }

  void _recordVolumeIntent(
    double value, {
    bool force = false,
    bool suppressHud = false,
  }) {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    final percent = (clamped * 100).round().clamp(0, 100);
    state = state.copyWith(volume: clamped);

    if (_latestDesiredVolumeSerial != 0 &&
        _latestDesiredVolumePercent == percent) {
      return;
    }
    if (!force &&
        _latestDesiredVolumeSerial == 0 &&
        _observedVolumePercent == percent) {
      return;
    }

    final requestSerial = _allocateVolumeRequestSerial();
    if (suppressHud) {
      _audioHudSuppression.suppress(requestSerial);
    }
    _pendingVolume = percent;
    _pendingVolumeSerial = requestSerial;
    _latestDesiredVolumePercent = percent;
    _latestDesiredVolumeSerial = requestSerial;
  }

  int _allocateVolumeRequestSerial() {
    final serial = _nextVolumeRequestSerial;
    _nextVolumeRequestSerial = serial >= 0xffffffff ? 1 : serial + 1;
    return serial;
  }

  void _scheduleVolumeApply({bool immediate = false}) {
    final generation = _buildGeneration;
    if (immediate) {
      _volumeTimer?.cancel();
      _volumeTimer = null;
      _flushVolume(generation);
      return;
    }
    _volumeTimer ??= Timer(_volumeCommitInterval, () {
      _volumeTimer = null;
      _flushVolume(generation);
    });
  }

  void _flushVolume(int generation) {
    if (!isBuildGenerationActive(generation) || _pendingVolume < 0) return;
    final pending = _pendingVolume;
    final requestSerial = _pendingVolumeSerial;
    _pendingVolume = -1;
    _pendingVolumeSerial = 0;
    try {
      _audio.apply(pending, requestSerial: requestSerial);
      if (_latestDesiredVolumeSerial == requestSerial) {
        _armVolumeAcknowledgementTimeout(requestSerial);
      }
    } on Object catch (error) {
      debugPrint('Unable to apply output volume: $error');
    }
  }

  void _handleAudioState(AudioLevelState update, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }

    final matchesLatestRequest =
        _latestDesiredVolumeSerial != 0 &&
        update.requestSerial == _latestDesiredVolumeSerial;
    if (matchesLatestRequest) {
      _volumeAcknowledgementTimer?.cancel();
      _volumeAcknowledgementTimer = null;
      _latestDesiredVolumeSerial = 0;
      _latestDesiredVolumePercent = -1;
      _deferredAudioState = null;
      _acceptAudioState(update);
      return;
    }

    // A non-zero serial is an acknowledgement for an older coalesced write.
    // It must never pull the thumb behind the user's latest intent.
    if (update.requestSerial != 0) {
      return;
    }

    if (_volumeInteracting || _latestDesiredVolumeSerial != 0) {
      _deferredAudioState = update;
      return;
    }

    _acceptAudioState(update);
  }

  void _acceptAudioState(AudioLevelState update) {
    final level = update.level.clamp(0.0, 1.0).toDouble();
    _observedVolumePercent = (level * 100).round().clamp(0, 100);
    if (!_volumeInteracting) {
      state = state.copyWith(volume: level);
    }
  }

  void _applyDeferredAudioStateIfIdle() {
    if (_volumeInteracting || _latestDesiredVolumeSerial != 0) {
      return;
    }
    final deferred = _deferredAudioState;
    _deferredAudioState = null;
    if (deferred != null) {
      _acceptAudioState(deferred);
    }
  }

  void _armVolumeAcknowledgementTimeout(int requestSerial) {
    _volumeAcknowledgementTimer?.cancel();
    final generation = _buildGeneration;
    _volumeAcknowledgementTimer = Timer(_volumeAcknowledgementTimeout, () {
      if (!isBuildGenerationActive(generation) ||
          _latestDesiredVolumeSerial != requestSerial) {
        return;
      }
      _latestDesiredVolumeSerial = 0;
      _latestDesiredVolumePercent = -1;
      _applyDeferredAudioStateIfIdle();
      unawaited(_audio.readLevel());
    });
  }

  void cycleProfile() {
    final next = PowerProfile.next(state.profile);
    state = state.copyWith(profile: next);
    unawaited(_power.write(next));
  }

  void openKeyboard() =>
      ref.read(referenceShellProvider.notifier).openEdgePanel();

  /// Captures a screenshot. The caller is expected to dismiss the shade first;
  /// the settle delay gives that animation time to clear the frame.
  Future<void> takeScreenshot() async {
    if (state.screenshotRunning) {
      return;
    }
    final generation = _buildGeneration;
    state = state.copyWith(screenshotRunning: true);
    try {
      await Future<void>.delayed(_screenshotSettleDelay);
      _actions.takeScreenshot();
    } finally {
      if (isBuildGenerationActive(generation)) {
        state = state.copyWith(screenshotRunning: false);
      }
    }
  }
}
