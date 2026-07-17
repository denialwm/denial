import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/denial_bridge.dart';
import 'shell_controller.dart';

final systemLevelHudProvider =
    StateNotifierProvider<SystemLevelHudController, SystemLevelHudState?>(
        (ref) {
  final bridge = ref.read(denialBridgeProvider);
  return SystemLevelHudController(
    brightnessStates: bridge.brightnessStates,
    audioStates: bridge.audioStates,
  );
});

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
class SystemLevelHudController extends StateNotifier<SystemLevelHudState?> {
  SystemLevelHudController({
    required Stream<DenialBrightnessState> brightnessStates,
    required Stream<DenialAudioState> audioStates,
    Duration visibleDuration = const Duration(milliseconds: 1200),
  })  : _visibleDuration = visibleDuration,
        super(null) {
    _brightnessSubscription = brightnessStates.listen(_handleBrightnessState);
    _audioSubscription = audioStates.listen(_handleAudioState);
  }

  final Duration _visibleDuration;
  late final StreamSubscription<DenialBrightnessState> _brightnessSubscription;
  late final StreamSubscription<DenialAudioState> _audioSubscription;
  Timer? _hideTimer;
  int _revision = 0;

  void _handleBrightnessState(DenialBrightnessState update) {
    _show(
      kind: SystemLevelHudKind.brightness,
      monitorId: update.monitorId,
      level: update.level,
    );
  }

  void _handleAudioState(DenialAudioState update) {
    if (update.completesRead) {
      return;
    }
    _show(
      kind: SystemLevelHudKind.audio,
      level: update.level,
    );
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
    _hideTimer = Timer(_visibleDuration, () {
      final current = state;
      if (current != null) {
        state = current.copyWith(visible: false);
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    unawaited(_brightnessSubscription.cancel());
    unawaited(_audioSubscription.cancel());
    super.dispose();
  }
}
