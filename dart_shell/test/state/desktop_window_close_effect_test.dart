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
      DesktopWindowCloseEffect.fromEnvironment(
        const <String, String>{
          'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'particles',
        },
      ),
      DesktopWindowCloseEffect.explosion,
    );
    expect(
      DesktopWindowCloseEffect.fromEnvironment(
        const <String, String>{
          'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'shrink',
        },
      ),
      DesktopWindowCloseEffect.implode,
    );
    expect(
      DesktopWindowCloseEffect.fromEnvironment(
        const <String, String>{
          'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'off',
        },
      ),
      DesktopWindowCloseEffect.none,
    );
  });

  test('invalid environment values retain the explosion default', () {
    expect(
      DesktopWindowCloseEffect.fromEnvironment(
        const <String, String>{
          'DENIA_DESKTOP_WINDOW_CLOSE_EFFECT': 'unknown',
        },
      ),
      DesktopWindowCloseEffect.explosion,
    );
  });

  test('controller changes the effect at runtime', () {
    final controller = DesktopWindowCloseEffectController();
    addTearDown(controller.dispose);

    controller.select(DesktopWindowCloseEffect.fade);

    expect(controller.state, DesktopWindowCloseEffect.fade);
  });
}
