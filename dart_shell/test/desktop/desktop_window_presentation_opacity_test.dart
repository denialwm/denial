import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/theme/glass_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktopWindowPresentationOpacity', () {
    test('keeps glass opacity stable across minimized presentations', () {
      expect(
        desktopWindowPresentationOpacity(
          transparencyMode: ShellTransparencyMode.glass,
          minimized: true,
          desktopWidget: false,
          windowOpacity: 0.72,
        ),
        0.72,
      );
      expect(
        desktopWindowPresentationOpacity(
          transparencyMode: ShellTransparencyMode.glass,
          minimized: false,
          desktopWidget: true,
          windowOpacity: 0.72,
        ),
        0.72,
      );
    });

    test('retains the existing blur minimize fade and desktop dimming', () {
      expect(
        desktopWindowPresentationOpacity(
          transparencyMode: ShellTransparencyMode.blur,
          minimized: true,
          desktopWidget: false,
          windowOpacity: 0.72,
        ),
        0.0,
      );
      expect(
        desktopWindowPresentationOpacity(
          transparencyMode: ShellTransparencyMode.blur,
          minimized: false,
          desktopWidget: true,
          windowOpacity: 0.5,
        ),
        0.43,
      );
    });

    test('uses the configured opacity for ordinary windows', () {
      for (final mode in ShellTransparencyMode.values) {
        expect(
          desktopWindowPresentationOpacity(
            transparencyMode: mode,
            minimized: false,
            desktopWidget: false,
            windowOpacity: 0.81,
          ),
          0.81,
        );
      }
    });
  });
}
