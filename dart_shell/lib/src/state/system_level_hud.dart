import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import 'notifier_lifecycle.dart';
import 'shell_controller.dart';

final systemLevelHudVisibleDurationProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 1200),
);

typedef SystemLevelHudSignals = ({
  Stream<DenialAudioState> audio,
  Stream<DenialBrightnessState> brightness,
});

final systemLevelHudSignalsProvider = Provider<SystemLevelHudSignals>((ref) {
  final bridge = ref.watch(denialBridgeProvider);
  return (audio: bridge.audioStates, brightness: bridge.brightnessStates);
});

final systemLevelHudProvider =
    NotifierProvider<SystemLevelHudController, SystemLevelHudState?>(
      SystemLevelHudController.new,
    );

enum SystemLevelHudKind { brightness, audio }

@immutable
class SystemLevelHudState {
  const SystemLevelHudState({
    required this.kind,
    required this.level,
    required this.visible,
    required this.revision,
    this.monitorId,
  });

  final SystemLevelHudKind kind;
  final int? monitorId;
  final double level;
  final bool visible;

  /// Changes for every native update, including equal level values.
  final int revision;

  SystemLevelHudState copyWith({bool? visible}) {
    return SystemLevelHudState(
      kind: kind,
      monitorId: monitorId,
      level: level,
      visible: visible ?? this.visible,
      revision: revision,
    );
  }
}

/// Presents the most recent native brightness or output-volume update.
///
/// Keeping both signals in one controller ensures that rapid changes across
/// the two controls replace one another instead of painting overlapping HUDs.
class SystemLevelHudController extends Notifier<SystemLevelHudState?>
    with NotifierLifecycle<SystemLevelHudState?> {
  @override
  SystemLevelHudState? build() {
    final signals = ref.watch(systemLevelHudSignalsProvider);
    _visibleDuration = ref.watch(systemLevelHudVisibleDurationProvider);
    _hideTimer = null;
    _revision = 0;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final brightnessSubscription = signals.brightness.listen(
      (update) => _handleBrightnessState(update, generation),
    );
    final audioSubscription = signals.audio.listen(
      (update) => _handleAudioState(update, generation),
    );
    cancelOnDispose(brightnessSubscription);
    cancelOnDispose(audioSubscription);
    ref.onDispose(() {
      _hideTimer?.cancel();
      _hideTimer = null;
    });
    return null;
  }

  late Duration _visibleDuration;
  late int _buildGeneration;
  Timer? _hideTimer;
  int _revision = 0;

  void _handleBrightnessState(DenialBrightnessState update, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    _show(
      kind: SystemLevelHudKind.brightness,
      monitorId: update.monitorId,
      level: update.level,
    );
  }

  void _handleAudioState(DenialAudioState update, int generation) {
    if (!isBuildGenerationActive(generation) || update.completesRead) {
      return;
    }
    _show(kind: SystemLevelHudKind.audio, level: update.level);
  }

  void _show({
    required SystemLevelHudKind kind,
    required double level,
    int? monitorId,
  }) {
    _hideTimer?.cancel();
    _revision += 1;
    state = SystemLevelHudState(
      kind: kind,
      monitorId: monitorId,
      level: level.clamp(0.0, 1.0).toDouble(),
      visible: true,
      revision: _revision,
    );
    final generation = _buildGeneration;
    _hideTimer = Timer(_visibleDuration, () {
      if (!isBuildGenerationActive(generation)) {
        return;
      }
      final current = state;
      if (current != null) {
        state = current.copyWith(visible: false);
      }
    });
  }
}
