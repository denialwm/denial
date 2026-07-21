import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_service.dart';
import 'notifier_lifecycle.dart';

final appAudioProvider = NotifierProvider<AppAudioController, AppAudioState>(
  AppAudioController.new,
);

class AppAudioState {
  const AppAudioState({
    required this.streams,
    required this.loading,
    required this.error,
  });

  const AppAudioState.initial()
    : streams = const <AppAudioStream>[],
      loading = true,
      error = null;

  final List<AppAudioStream> streams;
  final bool loading;
  final String? error;

  AppAudioState copyWith({
    List<AppAudioStream>? streams,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return AppAudioState(
      streams: streams ?? this.streams,
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class AppAudioController extends Notifier<AppAudioState>
    with NotifierLifecycle<AppAudioState> {
  @override
  AppAudioState build() {
    _audio = ref.watch(audioServiceProvider);
    _pendingVolumes.clear();
    _desiredVolumes.clear();
    _commitTimer = null;
    _responseTimer = null;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = _audio.appStreamStates.listen(
      (streams) => _handleStreams(streams, generation),
    );
    cancelOnDispose(subscription);
    ref.onDispose(() {
      _commitTimer?.cancel();
      _responseTimer?.cancel();
      _commitTimer = null;
      _responseTimer = null;
      _pendingVolumes.clear();
      _desiredVolumes.clear();
    });
    return const AppAudioState.initial();
  }

  static const Duration _commitInterval = Duration(milliseconds: 90);
  static const Duration _responseTimeout = Duration(seconds: 2);

  late AudioService _audio;
  late int _buildGeneration;
  final Map<int, int> _pendingVolumes = <int, int>{};
  final Map<int, int> _desiredVolumes = <int, int>{};
  Timer? _commitTimer;
  Timer? _responseTimer;

  void refresh() {
    state = state.copyWith(loading: state.streams.isEmpty, clearError: true);
    _audio.requestAppStreams();
    _armResponseTimeout();
  }

  void setVolume(int streamId, double value) {
    _recordVolume(streamId, value);
    _commitTimer ??= Timer(_commitInterval, _flushPendingVolumes);
  }

  void commitVolume(int streamId, double value) {
    _recordVolume(streamId, value);
    _commitTimer?.cancel();
    _commitTimer = null;
    _flushPendingVolumes();
  }

  void _recordVolume(int streamId, double value) {
    final percent = (value.clamp(0.0, 1.0) * 100).round().clamp(0, 100);
    _pendingVolumes[streamId] = percent;
    _desiredVolumes[streamId] = percent;
    state = state.copyWith(
      streams: List<AppAudioStream>.unmodifiable(
        state.streams.map(
          (stream) => stream.id == streamId
              ? stream.copyWith(level: percent / 100.0, muted: false)
              : stream,
        ),
      ),
    );
    _armResponseTimeout();
  }

  void _flushPendingVolumes() {
    _commitTimer?.cancel();
    _commitTimer = null;
    final pending = Map<int, int>.of(_pendingVolumes);
    _pendingVolumes.clear();
    for (final entry in pending.entries) {
      _audio.applyAppStream(entry.key, entry.value);
    }
  }

  void _handleStreams(List<AppAudioStream> streams, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final liveIds = streams.map((stream) => stream.id).toSet();
    _desiredVolumes.removeWhere((id, _) => !liveIds.contains(id));
    _pendingVolumes.removeWhere((id, _) => !liveIds.contains(id));

    final reconciled =
        streams
            .map((stream) {
              final desired = _desiredVolumes[stream.id];
              if (desired == null) {
                return stream;
              }
              final observed = (stream.level * 100).round().clamp(0, 100);
              if ((observed - desired).abs() <= 1 && !stream.muted) {
                _desiredVolumes.remove(stream.id);
                return stream;
              }
              return stream.copyWith(level: desired / 100.0, muted: false);
            })
            .toList(growable: false)
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    state = AppAudioState(
      streams: List<AppAudioStream>.unmodifiable(reconciled),
      loading: false,
      error: null,
    );
    if (_desiredVolumes.isEmpty) {
      _responseTimer?.cancel();
      _responseTimer = null;
    }
  }

  void _armResponseTimeout() {
    _responseTimer?.cancel();
    final generation = _buildGeneration;
    _responseTimer = Timer(_responseTimeout, () {
      if (!isBuildGenerationActive(generation)) {
        return;
      }
      final wasLoading = state.loading;
      _desiredVolumes.clear();
      _pendingVolumes.clear();
      state = state.copyWith(
        loading: false,
        error: wasLoading ? 'Unable to read application audio streams.' : null,
        clearError: !wasLoading,
      );
      if (!wasLoading) {
        _audio.requestAppStreams();
      }
    });
  }
}
