import 'dart:convert';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../models/display_layout.dart';
import '../models/shell_popup_placement.dart';
import '../state/desktop_window_close_effect.dart';
import '../theme/backdrop_blur_level.dart';
import '../theme/cursor_themes.dart';
import '../state/shell_controller.dart';
import '../platform/denial_bridge.dart';
import 'settings_store.dart';
import 'shell_settings.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) {
  return NativeSettingsStore(
    DenialSettingsDocumentTransport(ref.watch(denialBridgeProvider)),
  );
});

final shellSettingsProvider =
    NotifierProvider<ShellSettingsController, ShellSettings>(
      ShellSettingsController.new,
    );

enum ShellSettingsSyncPhase { loading, ready, failed }

class ShellSettingsSyncStatus {
  const ShellSettingsSyncStatus(this.phase);

  const ShellSettingsSyncStatus.loading()
    : phase = ShellSettingsSyncPhase.loading;

  const ShellSettingsSyncStatus.ready() : phase = ShellSettingsSyncPhase.ready;

  const ShellSettingsSyncStatus.failed()
    : phase = ShellSettingsSyncPhase.failed;

  final ShellSettingsSyncPhase phase;
}

final shellSettingsSyncStatusProvider =
    NotifierProvider<
      ShellSettingsSyncStatusController,
      ShellSettingsSyncStatus
    >(ShellSettingsSyncStatusController.new);

class ShellSettingsSyncStatusController
    extends Notifier<ShellSettingsSyncStatus> {
  @override
  ShellSettingsSyncStatus build() => const ShellSettingsSyncStatus.loading();

  void markLoading() => state = const ShellSettingsSyncStatus.loading();

  void markReady() => state = const ShellSettingsSyncStatus.ready();

  void markFailed() => state = const ShellSettingsSyncStatus.failed();
}

class ShellSettingsController extends Notifier<ShellSettings> {
  static const Duration _writeDebounce = Duration(milliseconds: 180);

  late SettingsStore _store;
  Timer? _writeTimer;
  StreamSubscription<DenialSettingsDocument>? _documentSubscription;
  int _mutationSerial = 0;
  int _buildSerial = 0;
  int _nativeDocumentSerial = 0;
  var _hasAuthoritativeState = false;
  late ShellSettings _initialSettings;
  late ShellSettings _latestSettings;
  late Completer<void> _initialLoad;
  final Map<String, Object?> _pendingRestorePatch = <String, Object?>{};

  @override
  ShellSettings build() {
    _store = ref.watch(settingsStoreProvider);
    _writeTimer?.cancel();
    _writeTimer = null;
    unawaited(_documentSubscription?.cancel());
    _documentSubscription = _store is SettingsDocumentUpdateSource
        ? (_store as SettingsDocumentUpdateSource).settingsDocumentUpdates
              .listen(_applyNativeDocument)
        : null;
    _mutationSerial = 0;
    _nativeDocumentSerial = 0;
    _hasAuthoritativeState = false;
    _pendingRestorePatch.clear();
    _initialLoad = Completer<void>();
    final buildSerial = ++_buildSerial;
    final nativeDocumentSerial = _nativeDocumentSerial;
    ref.onDispose(() {
      final hadPendingWrite = _writeTimer != null;
      final pendingSettings = hadPendingWrite && _hasAuthoritativeState
          ? _latestSettings
          : null;
      _writeTimer?.cancel();
      _writeTimer = null;
      unawaited(_documentSubscription?.cancel());
      _documentSubscription = null;
      if (pendingSettings != null) {
        unawaited(_store.write(pendingSettings).catchError((Object _) {}));
      }
    });
    _initialSettings = ShellSettings(
      animations: ShellAnimationSettings(
        windowCloseEffect: DesktopWindowCloseEffect.fromEnvironment(
          ref.watch(startupEnvironmentProvider).values,
        ),
      ),
    );
    _latestSettings = _initialSettings;
    scheduleMicrotask(
      () => unawaited(_restore(buildSerial, nativeDocumentSerial)),
    );
    return _initialSettings;
  }

  void _applyNativeDocument(DenialSettingsDocument document) {
    try {
      final decoded = jsonDecode(document.json);
      if (decoded is Map<String, dynamic>) {
        _nativeDocumentSerial += 1;
        _acceptAuthoritativeState(ShellSettings.fromJson(decoded));
      }
    } on FormatException {
      // The compositor validates and owns this document. Ignore a malformed
      // notification defensively and retain the last known-good UI state.
    }
  }

  void setLocalePreference(ShellLocalePreference value) {
    _update(
      state.copyWith(localization: state.localization.copyWith(locale: value)),
    );
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

  void setWindowRadius(double value) {
    _updateAppearance(windowRadius: value.clamp(0, 48).toDouble());
  }

  void setPanelRadius(double value) {
    _updateAppearance(panelRadius: value.clamp(8, 56).toDouble());
  }

  void setPanelOpacity(double value) {
    _updateAppearance(panelOpacity: value.clamp(0.35, 1).toDouble());
  }

  void setBackdropBlurEnabled(bool value) {
    _updateAppearance(backdropBlurEnabled: value);
  }

  void setBackdropBlurLevel(ShellBackdropBlurLevel value) {
    _updateAppearance(backdropBlurLevel: value);
  }

  void setBackdropBlurOpacityThreshold(double value) {
    _updateAppearance(
      backdropBlurOpacityThreshold: value.clamp(0, 1).toDouble(),
    );
  }

  void setFocusedWindowOpacity(double value) {
    _updateAppearance(focusedWindowOpacity: value.clamp(0.35, 1).toDouble());
  }

  void setUnfocusedWindowOpacity(double value) {
    _updateAppearance(unfocusedWindowOpacity: value.clamp(0.2, 1).toDouble());
  }

  void setCursorSize(double value) {
    _updateAppearance(
      cursorSize: value
          .clamp(shellCursorMinimumSize, shellCursorMaximumSize)
          .toDouble(),
    );
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

  void setClipboardTrayEdge(ClipboardTrayEdge value) {
    _update(
      state.copyWith(layout: state.layout.copyWith(clipboardTrayEdge: value)),
    );
  }

  void setClipboardTrayExtent(double value) {
    _update(
      state.copyWith(
        layout: state.layout.copyWith(
          clipboardTrayExtent: value
              .clamp(clipboardTrayMinimumExtent, clipboardTrayMaximumExtent)
              .toDouble(),
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

  void setWindowCloseEffect(DesktopWindowCloseEffect value) {
    _update(
      state.copyWith(
        animations: state.animations.copyWith(windowCloseEffect: value),
      ),
    );
  }

  void setAnimationDurationScale(double value) {
    _update(
      state.copyWith(
        animations: state.animations.copyWith(
          durationScale: value.clamp(0.5, 2).toDouble(),
        ),
      ),
    );
  }

  void setPanelTravel(double value) {
    _update(
      state.copyWith(
        animations: state.animations.copyWith(
          panelTravel: value.clamp(0, 96).toDouble(),
        ),
      ),
    );
  }

  void setLockScreenAnimationEnabled(bool value) {
    _update(
      state.copyWith(
        animations: state.animations.copyWith(animateLockScreen: value),
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

  void setIdleDpmsEnabled(bool value) {
    _update(
      state.copyWith(power: state.power.copyWith(idleDpmsEnabled: value)),
    );
  }

  void setIdleDpmsTimeoutMinutes(int value) {
    _update(
      state.copyWith(
        power: state.power.copyWith(
          idleDpmsTimeoutMinutes: value
              .clamp(
                ShellPowerSettings.minimumIdleDpmsMinutes,
                ShellPowerSettings.maximumIdleDpmsMinutes,
              )
              .toInt(),
        ),
      ),
    );
  }

  void resetAppearance() {
    _update(state.copyWith(appearance: const ShellAppearanceSettings()));
  }

  void resetLocalization() {
    _update(state.copyWith(localization: const ShellLocalizationSettings()));
  }

  void resetLayout() {
    _update(state.copyWith(layout: const ShellLayoutSettings()));
  }

  void resetOverlays() {
    _update(state.copyWith(overlays: const ShellOverlaySettings()));
  }

  void resetAnimations() {
    _update(state.copyWith(animations: const ShellAnimationSettings()));
  }

  void resetLockScreen() {
    _update(state.copyWith(lockScreen: const ShellLockScreenSettings()));
  }

  void resetPower() {
    _update(state.copyWith(power: const ShellPowerSettings()));
  }

  Future<void> flush() async {
    if (!_hasAuthoritativeState) {
      await _initialLoad.future;
    }
    if (!_hasAuthoritativeState) {
      throw StateError('Denial settings are not synchronized');
    }
    _writeTimer?.cancel();
    _writeTimer = null;
    await _store.write(state);
  }

  Future<void> retrySynchronization() async {
    ref.read(shellSettingsSyncStatusProvider.notifier).markLoading();
    if (_initialLoad.isCompleted) {
      _initialLoad = Completer<void>();
    }
    await _restore(_buildSerial, _nativeDocumentSerial);
  }

  void _updateAppearance({
    double? windowRadius,
    double? panelRadius,
    double? panelOpacity,
    bool? backdropBlurEnabled,
    ShellBackdropBlurLevel? backdropBlurLevel,
    double? backdropBlurOpacityThreshold,
    double? focusedWindowOpacity,
    double? unfocusedWindowOpacity,
    double? cursorSize,
  }) {
    _update(
      state.copyWith(
        appearance: state.appearance.copyWith(
          windowRadius: windowRadius,
          panelRadius: panelRadius,
          panelOpacity: panelOpacity,
          backdropBlurEnabled: backdropBlurEnabled,
          backdropBlurLevel: backdropBlurLevel,
          backdropBlurOpacityThreshold: backdropBlurOpacityThreshold,
          focusedWindowOpacity: focusedWindowOpacity,
          unfocusedWindowOpacity: unfocusedWindowOpacity,
          cursorSize: cursorSize,
        ),
      ),
    );
  }

  void _update(ShellSettings next) {
    if (next == state) {
      return;
    }
    if (!_hasAuthoritativeState) {
      _mergeSettingsDifference(
        _pendingRestorePatch,
        state.toJson(),
        next.toJson(),
      );
    }
    _mutationSerial += 1;
    state = next;
    _latestSettings = next;
    if (!_hasAuthoritativeState) {
      return;
    }
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDebounce, () => unawaited(_writeSafely()));
  }

  Future<void> _restore(int buildSerial, int nativeDocumentSerial) async {
    ShellSettings? restored;
    try {
      restored = await _store.read();
    } on Object {
      if (ref.mounted &&
          buildSerial == _buildSerial &&
          nativeDocumentSerial == _nativeDocumentSerial) {
        ref.read(shellSettingsSyncStatusProvider.notifier).markFailed();
        if (!_initialLoad.isCompleted) {
          _initialLoad.complete();
        }
      }
      return;
    }
    if (!ref.mounted ||
        buildSerial != _buildSerial ||
        nativeDocumentSerial != _nativeDocumentSerial) {
      return;
    }
    _acceptAuthoritativeState(restored ?? _initialSettings);
  }

  Future<void> _writeSafely() async {
    final writeSerial = _mutationSerial;
    try {
      await flush();
    } on Object {
      if (writeSerial != _mutationSerial) {
        return;
      }
      try {
        final restored = await _store.read();
        if (writeSerial == _mutationSerial && restored != null) {
          _pendingRestorePatch.clear();
          _hasAuthoritativeState = true;
          state = restored;
          _latestSettings = restored;
        }
      } on Object {
        // The failed write remains the primary error. Retain the optimistic
        // state if the authoritative rollback cannot be read either.
      }
      if (!ref.mounted) {
        return;
      }
      ref.read(shellSettingsSyncStatusProvider.notifier).markFailed();
    }
  }

  void _acceptAuthoritativeState(ShellSettings restored) {
    final hadPendingMutations = _pendingRestorePatch.isNotEmpty;
    var resolved = restored;
    if (hadPendingMutations) {
      final document = restored.toJson();
      _applySettingsPatch(document, _pendingRestorePatch);
      resolved = ShellSettings.fromJson(document);
      _pendingRestorePatch.clear();
    }
    _hasAuthoritativeState = true;
    _mutationSerial += 1;
    state = resolved;
    _latestSettings = resolved;
    ref.read(shellSettingsSyncStatusProvider.notifier).markReady();
    if (!_initialLoad.isCompleted) {
      _initialLoad.complete();
    }
    if (hadPendingMutations) {
      _writeTimer?.cancel();
      _writeTimer = Timer(_writeDebounce, () => unawaited(_writeSafely()));
    }
  }
}

void _mergeSettingsDifference(
  Map<String, Object?> patch,
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  for (final entry in after.entries) {
    final previous = before[entry.key];
    final next = entry.value;
    if (previous is Map<String, dynamic> && next is Map<String, dynamic>) {
      final nested = <String, Object?>{};
      _mergeSettingsDifference(nested, previous, next);
      if (nested.isNotEmpty) {
        final existing = patch[entry.key];
        if (existing is Map<String, Object?>) {
          _applySettingsPatch(existing, nested);
        } else {
          patch[entry.key] = nested;
        }
      }
    } else if (previous != next) {
      patch[entry.key] = next;
    }
  }
}

void _applySettingsPatch(
  Map<String, dynamic> document,
  Map<String, Object?> patch,
) {
  for (final entry in patch.entries) {
    final current = document[entry.key];
    final next = entry.value;
    if (current is Map<String, dynamic> && next is Map<String, Object?>) {
      _applySettingsPatch(current, next);
    } else {
      document[entry.key] = next;
    }
  }
}
