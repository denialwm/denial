import 'package:denial_dart_shell/src/desktop/window_backdrop_blur_policy.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decoration-only alpha does not request backdrop blur', () {
    final window = _window(
      opacityClass: DenialWindowOpacityClass.borderAlphaOnly,
    );

    expect(
      desktopWindowBackdropBlurEnabled(
        window: window,
        shellOpacity: 1,
        opacityThreshold: 0.05,
      ),
      isFalse,
    );
  });

  test('meaningful content translucency requests backdrop blur', () {
    final window = _window(
      opacityClass: DenialWindowOpacityClass.contentTranslucent,
    );

    expect(
      desktopWindowBackdropBlurEnabled(
        window: window,
        shellOpacity: 1,
        opacityThreshold: 0.05,
      ),
      isTrue,
    );
  });

  test('effective opacity must reach the global blur threshold', () {
    final below = _window(
      opacity: 0.04,
      opacityClass: DenialWindowOpacityClass.contentTranslucent,
    );
    final atThreshold = _window(
      opacity: 0.05,
      opacityClass: DenialWindowOpacityClass.contentTranslucent,
    );
    final invisible = _window(
      opacity: 0,
      opacityClass: DenialWindowOpacityClass.contentTranslucent,
    );

    expect(_blur(below), isFalse);
    expect(_blur(atThreshold), isTrue);
    expect(_blur(invisible, threshold: 0), isFalse);
  });

  test('shell-wide translucency still requests blur above the threshold', () {
    final opaque = _window(opacityClass: DenialWindowOpacityClass.fullyOpaque);

    expect(_blur(opaque, shellOpacity: 0.8), isTrue);
    expect(_blur(opaque, shellOpacity: 0.04), isFalse);
  });
}

bool _blur(
  DenialWindow window, {
  double shellOpacity = 1,
  double threshold = 0.05,
}) {
  return desktopWindowBackdropBlurEnabled(
    window: window,
    shellOpacity: shellOpacity,
    opacityThreshold: threshold,
  );
}

DenialWindow _window({
  double opacity = 1,
  required DenialWindowOpacityClass opacityClass,
}) {
  return DenialWindow(
    objectId: 1,
    objectKind: 'root_surface',
    surfaceId: 1,
    windowId: 1,
    textureId: 1,
    title: 'Test',
    appId: 'dev.denial.test',
    width: 100,
    height: 80,
    surfaceX: 0,
    surfaceY: 0,
    surfaceWidth: 100,
    surfaceHeight: 80,
    textureSourceX: 0,
    textureSourceY: 0,
    textureSourceWidth: 100,
    textureSourceHeight: 80,
    geometryX: 0,
    geometryY: 0,
    geometryWidth: 100,
    geometryHeight: 80,
    monitorId: 1,
    transform: 0,
    scale120: 120,
    opacity: opacity,
    opacityClass: opacityClass,
  );
}
