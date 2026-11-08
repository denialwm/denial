import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A small on/off system control backed by a helper CLI: auto brightness
/// (`nabu-autobrightness`) and the camera torch (`torch`).
@immutable
class SystemToggleState {
  const SystemToggleState({
    this.enabled = false,
    this.busy = false,
    this.error,
  });

  final bool enabled;
  final bool busy;
  final String? error;

  SystemToggleState copyWith({
    bool? enabled,
    bool? busy,
    String? error,
    bool clearError = false,
  }) {
    return SystemToggleState(
      enabled: enabled ?? this.enabled,
      busy: busy ?? this.busy,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final autoBrightnessProvider =
    NotifierProvider<AutoBrightnessController, SystemToggleState>(
      AutoBrightnessController.new,
    );

final flashlightProvider =
    NotifierProvider<FlashlightController, SystemToggleState>(
      FlashlightController.new,
    );

class AutoBrightnessController extends Notifier<SystemToggleState> {
  static final _status = RegExp(r'Daemon Status:\s*([^\r\n]+)');
  static final _ansi = RegExp(r'\x1b\[[0-9;]*m');

  @override
  SystemToggleState build() => const SystemToggleState();

  Future<void> refresh() async {
    try {
      final result = await Process.run('nabu-autobrightness', const <String>[
        'status',
      ]).timeout(const Duration(seconds: 4));
      final text = '${result.stdout}\n${result.stderr}'.replaceAll(_ansi, '');
      final match = _status.firstMatch(text);
      final value = (match?.group(1) ?? '').toLowerCase().trim();
      state = SystemToggleState(
        enabled: value.startsWith('active') || value.startsWith('running'),
      );
    } on Object catch (error) {
      state = SystemToggleState(error: '$error');
    }
  }

  Future<void> toggle() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await Process.run('nabu-autobrightness', const <String>[
        'toggle',
      ]).timeout(const Duration(seconds: 6));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await refresh();
      state = state.copyWith(busy: false);
    } on Object catch (error) {
      state = SystemToggleState(error: '$error');
    }
  }
}

class FlashlightController extends Notifier<SystemToggleState> {
  static final _status = RegExp(r'State:\s*(ON|OFF)', caseSensitive: false);

  @override
  SystemToggleState build() => const SystemToggleState();

  Future<void> refresh() async {
    try {
      final result = await Process.run('torch', const <String>[
        'status',
      ]).timeout(const Duration(seconds: 4));
      final text = '${result.stdout}\n${result.stderr}';
      final match = _status.firstMatch(text);
      state = SystemToggleState(
        enabled: match?.group(1)?.toUpperCase() == 'ON',
      );
    } on Object catch (error) {
      state = SystemToggleState(error: '$error');
    }
  }

  Future<void> toggle() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await Process.run('torch', const <String>[
        'toggle',
      ]).timeout(const Duration(seconds: 6));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await refresh();
      state = state.copyWith(busy: false);
    } on Object catch (error) {
      state = SystemToggleState(error: '$error');
    }
  }
}
