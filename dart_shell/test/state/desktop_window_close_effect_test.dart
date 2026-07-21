import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/state/desktop_window_close_effect.dart';

void main() {
  test('explosion is the default desktop close effect', () {
    expect(
      DesktopWindowCloseEffect.fromEnvironment(const <String, String>{}),
      DesktopWindowCloseEffect.explosion,
    );
  });

  test('desktop close effect accepts environment aliases', () {
    expect(
      DesktopWindowCloseEffect.fromEnvironment(const <String, String>{
        'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'particles',
      }),
      DesktopWindowCloseEffect.explosion,
    );
    expect(
      DesktopWindowCloseEffect.fromEnvironment(const <String, String>{
        'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'shrink',
      }),
      DesktopWindowCloseEffect.implode,
    );
    expect(
      DesktopWindowCloseEffect.fromEnvironment(const <String, String>{
        'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'off',
      }),
      DesktopWindowCloseEffect.none,
    );
  });

  test('invalid environment values retain the explosion default', () {
    expect(
      DesktopWindowCloseEffect.fromEnvironment(const <String, String>{
        'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'unknown',
      }),
      DesktopWindowCloseEffect.explosion,
    );
  });

  test('controller changes the effect at runtime', () {
    final container = ProviderContainer.test();
    final controller = container.read(
      desktopWindowCloseEffectProvider.notifier,
    );

    controller.select(DesktopWindowCloseEffect.fade);

    expect(
      container.read(desktopWindowCloseEffectProvider),
      DesktopWindowCloseEffect.fade,
    );
  });
}
