import 'dart:async';

import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      const ShellSettings(appearance: ShellAppearanceSettings(windowRadius: 7)),
    );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(shellSettingsProvider).appearance.windowRadius, 29);
    await container.read(shellSettingsProvider.notifier).flush();
    expect(store.writes.single.appearance.windowRadius, 29);
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

  test('backdrop blur updates live and clamps GPU intensity', () async {
    final store = _MemorySettingsStore(Future<ShellSettings?>.value(null));
    final container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);

    controller
      ..setBackdropBlurEnabled(false)
      ..setBackdropBlurSigma(200)
      ..setBackdropBlurOpacityThreshold(-2);

    final appearance = container.read(shellSettingsProvider).appearance;
    expect(appearance.backdropBlurEnabled, isFalse);
    expect(appearance.backdropBlurSigma, 32);
    expect(appearance.backdropBlurOpacityThreshold, 0);
    await controller.flush();
    expect(store.writes.single.appearance, appearance);
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
    expect(layout.clipboardTrayExtent, 720);
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
