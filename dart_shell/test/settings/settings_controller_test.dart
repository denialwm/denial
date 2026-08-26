import 'dart:async';
import 'dart:convert';

import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seeded settings streams initialize without a separate read', () async {
    final store = _StreamingSettingsStore();
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    addTearDown(store.dispose);

    container.read(shellSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    store.publish(
      const ShellSettings(
        appearance: ShellAppearanceSettings(windowRadius: 31),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.reads, 0);
    expect(container.read(shellSettingsProvider).appearance.windowRadius, 31);
    expect(
      container.read(shellSettingsSyncStatusProvider).phase,
      ShellSettingsSyncPhase.ready,
    );
  });

  test('native revisions merge beneath a pending debounced edit', () async {
    final store = _StreamingSettingsStore();
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    addTearDown(store.dispose);

    final controller = container.read(shellSettingsProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    store.publish(
      const ShellSettings(
        appearance: ShellAppearanceSettings(
          windowRadius: 12,
          panelOpacity: 0.7,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    controller.setWindowRadius(29);
    store.publish(
      const ShellSettings(
        appearance: ShellAppearanceSettings(
          windowRadius: 12,
          panelOpacity: 0.63,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final merged = container.read(shellSettingsProvider);
    expect(merged.appearance.windowRadius, 29);
    expect(merged.appearance.panelOpacity, 0.63);
    await controller.flush();
    expect(store.writes.single, merged);
  });

  test('a late disk read cannot overwrite an immediate user change', () async {
    final read = Completer<ShellSettings?>();
    final store = _MemorySettingsStore(read.future);
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(container.read(shellSettingsProvider), const ShellSettings());
    container.read(shellSettingsProvider.notifier).setWindowRadius(29);
    await Future<void>.delayed(Duration.zero);
    read.complete(
      const ShellSettings(
        appearance: ShellAppearanceSettings(
          windowRadius: 7,
          panelOpacity: 0.63,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final settings = container.read(shellSettingsProvider);
    expect(settings.appearance.windowRadius, 29);
    expect(settings.appearance.panelOpacity, 0.63);
    expect(
      container.read(shellSettingsSyncStatusProvider).phase,
      ShellSettingsSyncPhase.ready,
    );
    await container.read(shellSettingsProvider.notifier).flush();
    expect(store.writes.single.appearance.windowRadius, 29);
    expect(store.writes.single.appearance.panelOpacity, 0.63);
  });

  test('a failed authoritative read cannot write default settings', () async {
    final read = Completer<ShellSettings?>();
    final store = _MemorySettingsStore(read.future);
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller.setBackdropBlurEnabled(false);
    read.completeError(StateError('control socket unavailable'));
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(shellSettingsSyncStatusProvider).phase,
      ShellSettingsSyncPhase.failed,
    );
    await expectLater(controller.flush(), throwsStateError);
    expect(store.writes, isEmpty);
  });

  test('rapid changes coalesce into one explicit flush', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller
      ..setPanelOpacity(0.8)
      ..setPanelOpacity(0.7)
      ..setPanelOpacity(0.6);
    await controller.flush();

    expect(store.writes, hasLength(1));
    expect(store.writes.single.appearance.panelOpacity, 0.6);
  });

  test(
    'panel radius accepts zero and clamps negative values to zero',
    () async {
      final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
      final container = ProviderContainer.test(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(shellSettingsProvider.notifier);

      controller.setPanelRadius(0);
      expect(container.read(shellSettingsProvider).appearance.panelRadius, 0);
      controller.setPanelRadius(-12);
      expect(container.read(shellSettingsProvider).appearance.panelRadius, 0);

      await controller.flush();
      expect(store.writes.single.appearance.panelRadius, 0);
    },
  );

  test(
    'a failed colour-scheme write restores the authoritative theme',
    () async {
      final authoritative = const ShellSettings();
      final store = _FailingSettingsStore(authoritative);
      final container = ProviderContainer.test(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(shellSettingsProvider.notifier);

      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(shellSettingsSyncStatusProvider).phase,
        ShellSettingsSyncPhase.ready,
      );

      controller.setColorSchemePreference(
        DesktopColorSchemePreference.preferLight,
      );
      expect(
        container.read(shellSettingsProvider).appearance.colorSchemePreference,
        DesktopColorSchemePreference.preferLight,
      );

      await store.writeAttempted.future;
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(shellSettingsProvider).appearance.colorSchemePreference,
        DesktopColorSchemePreference.preferDark,
      );
      expect(
        container.read(shellSettingsSyncStatusProvider).phase,
        ShellSettingsSyncPhase.failed,
      );
      expect(store.reads, 2);
    },
  );

  test('backdrop blur quality updates live', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller
      ..setBackdropBlurEnabled(false)
      ..setBackdropBlurLevel(ShellBackdropBlurLevel.shitty)
      ..setBackdropBlurOpacityThreshold(-2);

    final appearance = container.read(shellSettingsProvider).appearance;
    expect(appearance.backdropBlurEnabled, isFalse);
    expect(appearance.backdropBlurLevel, ShellBackdropBlurLevel.shitty);
    expect(appearance.backdropBlurOpacityThreshold, 0);
    await controller.flush();
    expect(store.writes.single.appearance, appearance);
  });

  test('cursor size applies live, clamps, and persists', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller.setCursorSize(200);
    expect(
      container.read(shellSettingsProvider).appearance.cursorSize,
      shellCursorMaximumSize,
    );
    controller.setCursorSize(8);
    expect(
      container.read(shellSettingsProvider).appearance.cursorSize,
      shellCursorMinimumSize,
    );
    await controller.flush();
    expect(store.writes.single.appearance.cursorSize, shellCursorMinimumSize);
  });

  test('power timeout stays inside the compositor-supported range', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller.setIdleDpmsTimeoutMinutes(999);
    expect(
      container.read(shellSettingsProvider).power.idleDpmsTimeoutMinutes,
      ShellPowerSettings.maximumIdleDpmsMinutes,
    );
    controller.setIdleDpmsTimeoutMinutes(-1);
    expect(
      container.read(shellSettingsProvider).power.idleDpmsTimeoutMinutes,
      ShellPowerSettings.minimumIdleDpmsMinutes,
    );
    await controller.flush();
  });

  test('locale preference applies live and persists', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller.setLocalePreference(ShellLocalePreference.simplifiedChinese);
    expect(
      container.read(shellSettingsProvider).localization.locale,
      ShellLocalePreference.simplifiedChinese,
    );
    await controller.flush();
    expect(
      store.writes.single.localization.locale,
      ShellLocalePreference.simplifiedChinese,
    );

    controller.resetLocalization();
    expect(
      container.read(shellSettingsProvider).localization.locale,
      ShellLocalePreference.system,
    );
  });

  test('clipboard tray placement persists and clamps its extent', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller
      ..setClipboardTrayEdge(ClipboardTrayEdge.top)
      ..setClipboardTrayExtent(900);

    final layout = container.read(shellSettingsProvider).layout;
    expect(layout.clipboardTrayEdge, ClipboardTrayEdge.top);
    expect(layout.clipboardTrayExtent, clipboardTrayMaximumExtent);
    await controller.flush();
    expect(store.writes.single.layout, layout);
  });
}

class _MemorySettingsStore implements SettingsStore {
  _MemorySettingsStore(this._read);

  final Future<ShellSettings?> _read;
  final List<ShellSettings> writes = <ShellSettings>[];

  @override
  Future<ShellSettings?> read() => _read;

  @override
  Future<void> write(ShellSettings settings) async {
    writes.add(settings);
  }
}

class _FailingSettingsStore implements SettingsStore {
  _FailingSettingsStore(this.authoritative);

  final ShellSettings authoritative;
  final Completer<void> writeAttempted = Completer<void>();
  int reads = 0;

  @override
  Future<ShellSettings?> read() async {
    reads += 1;
    return authoritative;
  }

  @override
  Future<void> write(ShellSettings settings) async {
    if (!writeAttempted.isCompleted) {
      writeAttempted.complete();
    }
    throw StateError('native commit rejected');
  }
}

class _StreamingSettingsStore
    implements SettingsStore, SettingsDocumentUpdateSource {
  final _updates = StreamController<DenialSettingsDocument>.broadcast(
    sync: true,
  );
  var revision = 0;
  var reads = 0;
  final List<ShellSettings> writes = <ShellSettings>[];

  @override
  Stream<DenialSettingsDocument> get settingsDocumentUpdates => _updates.stream;

  void publish(ShellSettings settings) {
    revision += 1;
    _updates.add(
      DenialSettingsDocument(
        revision: revision,
        json: '${jsonEncode(settings.toJson())}\n',
      ),
    );
  }

  @override
  Future<ShellSettings?> read() async {
    reads += 1;
    return null;
  }

  @override
  Future<void> write(ShellSettings settings) async {
    writes.add(settings);
  }

  Future<void> dispose() => _updates.close();
}
