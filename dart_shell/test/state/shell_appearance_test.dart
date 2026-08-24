import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'backdrop blur changes immediately and stays in its supported range',
    () {
      final container = _settingsContainer();
      addTearDown(container.dispose);
      final controller = container.read(shellSettingsProvider.notifier);

      controller
        ..setBackdropBlurEnabled(false)
        ..setBackdropBlurLevel(ShellBackdropBlurLevel.shitty)
        ..setBackdropBlurOpacityThreshold(4);

      final appearance = container.read(shellSettingsProvider).appearance;
      expect(appearance.backdropBlurEnabled, isFalse);
      expect(appearance.backdropBlurLevel, ShellBackdropBlurLevel.shitty);
      expect(appearance.backdropBlurOpacityThreshold, 1);
    },
  );

  test('backdrop blur can return to the shell default', () {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    final controller = container.read(shellSettingsProvider.notifier);
    controller
      ..setBackdropBlurEnabled(false)
      ..setBackdropBlurLevel(ShellBackdropBlurLevel.fast);

    controller.resetAppearance();

    expect(
      container.read(shellSettingsProvider).appearance,
      const ShellAppearanceSettings(),
    );
  });
}

ProviderContainer _settingsContainer() {
  return ProviderContainer.test(
    overrides: [
      settingsStoreProvider.overrideWithValue(const _MemorySettingsStore()),
    ],
  );
}

class _MemorySettingsStore implements SettingsStore {
  const _MemorySettingsStore();

  @override
  Future<ShellSettings?> read() async => null;

  @override
  Future<void> write(ShellSettings settings) async {}
}
