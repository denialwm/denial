import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/launcher_providers.dart';
import '../models/display_layout.dart';
import '../models/shell_popup_placement.dart';
import 'settings_store.dart';
import 'shell_settings.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) {
  return FileSettingsStore(ref.watch(runtimePathsProvider));
});

final shellSettingsProvider =
    NotifierProvider<ShellSettingsController, ShellSettings>(
      ShellSettingsController.new,
    );

class ShellSettingsController extends Notifier<ShellSettings> {
  static const Duration _writeDebounce = Duration(milliseconds: 180);

  late SettingsStore _store;
  Timer? _writeTimer;
  int _mutationSerial = 0;
  int _buildSerial = 0;

  @override
  ShellSettings build() {
    _store = ref.watch(settingsStoreProvider);
    _writeTimer?.cancel();
    _writeTimer = null;
    _mutationSerial = 0;
    final buildSerial = ++_buildSerial;
    ref.onDispose(() {
      final hadPendingWrite = _writeTimer != null;
      _writeTimer?.cancel();
      _writeTimer = null;
      if (hadPendingWrite) {
        unawaited(_writeSafely());
      }
    });
    scheduleMicrotask(() => unawaited(_restore(buildSerial)));
    return const ShellSettings();
  }

  void setAccentSource(ShellAccentSource source) {
    _update(
      state.copyWith(
        appearance: state.appearance.copyWith(accentSource: source),
      ),
    );
  }

  void setCustomAccentColor(Color color) {
    _update(
      state.copyWith(
        appearance: state.appearance.copyWith(
          customAccentColor: color.withAlpha(0xff),
        ),
      ),
    );
  }

  void setFocusedWindowBorderColor(Color color) {
    _update(
      state.copyWith(
        appearance: state.appearance.copyWith(
          focusedWindowBorderColor: color.withAlpha(0xff),
        ),
      ),
    );
  }

  void setWindowRadius(double value) {
    _updateAppearance(windowRadius: value.clamp(0, 48).toDouble());
  }

  void setPanelRadius(double value) {
    _updateAppearance(panelRadius: value.clamp(8, 56).toDouble());
  }

  void setPanelOpacity(double value) {
    _updateAppearance(panelOpacity: value.clamp(0.35, 1).toDouble());
  }

  void setFocusedWindowOpacity(double value) {
    _updateAppearance(focusedWindowOpacity: value.clamp(0.35, 1).toDouble());
  }

  void setUnfocusedWindowOpacity(double value) {
    _updateAppearance(unfocusedWindowOpacity: value.clamp(0.2, 1).toDouble());
  }

  void setSystemBarPlacement({
    required SystemBarSide side,
    required Iterable<String> outputNames,
  }) {
    _update(
      state.copyWith(
        layout: state.layout.copyWith(
          systemBarSide: side,
          systemBarOutputNames: outputNames.toSet().toList(growable: false),
        ),
      ),
    );
  }

  void setSystemBarThickness(double value) {
    _update(
      state.copyWith(
        layout: state.layout.copyWith(
          systemBarThickness: value.clamp(24, 112).toDouble(),
        ),
      ),
    );
  }

  void setMaximizePadding(double value) {
    _update(
      state.copyWith(
        layout: state.layout.copyWith(
          maximizePadding: value.clamp(0, 64).toDouble(),
        ),
      ),
    );
  }

  void setOverlayPlacement(
    ShellOverlaySurface surface,
    ShellPopupPlacement placement,
  ) {
    _update(
      state.copyWith(
        overlays: state.overlays.withPlacement(surface, placement),
      ),
    );
  }

  void setLockScreen({
    bool? useSystemWallpaper,
    double? dimAmount,
    double? blurRadius,
    double? clockScale,
    bool? showSystemStatus,
  }) {
    _update(
      state.copyWith(
        lockScreen: state.lockScreen.copyWith(
          useSystemWallpaper: useSystemWallpaper,
          dimAmount: dimAmount?.clamp(0, 0.85).toDouble(),
          blurRadius: blurRadius?.clamp(0, 32).toDouble(),
          clockScale: clockScale?.clamp(0.65, 1.4).toDouble(),
          showSystemStatus: showSystemStatus,
        ),
      ),
    );
  }

  void resetAppearance() {
    _update(state.copyWith(appearance: const ShellAppearanceSettings()));
  }

  void resetLayout() {
    _update(state.copyWith(layout: const ShellLayoutSettings()));
  }

  void resetOverlays() {
    _update(state.copyWith(overlays: const ShellOverlaySettings()));
  }

  void resetLockScreen() {
    _update(state.copyWith(lockScreen: const ShellLockScreenSettings()));
  }

  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    await _store.write(state);
  }

  void _updateAppearance({
    double? windowRadius,
    double? panelRadius,
    double? panelOpacity,
    double? focusedWindowOpacity,
    double? unfocusedWindowOpacity,
  }) {
    _update(
      state.copyWith(
        appearance: state.appearance.copyWith(
          windowRadius: windowRadius,
          panelRadius: panelRadius,
          panelOpacity: panelOpacity,
          focusedWindowOpacity: focusedWindowOpacity,
          unfocusedWindowOpacity: unfocusedWindowOpacity,
        ),
      ),
    );
  }

  void _update(ShellSettings next) {
    if (next == state) {
      return;
    }
    _mutationSerial += 1;
    state = next;
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDebounce, () => unawaited(_writeSafely()));
  }

  Future<void> _restore(int buildSerial) async {
    final mutationSerial = _mutationSerial;
    final restored = await _store.read();
    if (buildSerial != _buildSerial ||
        mutationSerial != _mutationSerial ||
        restored == null) {
      return;
    }
    state = restored;
  }

  Future<void> _writeSafely() async {
    try {
      await flush();
    } on Object {
      // Settings are non-critical shell policy. A transient storage failure
      // must not escape the timer zone or take down the compositor UI.
    }
  }
}
