import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scene comparison ignores title-only presentation metadata', () {
    final first = _window(title: 'Building ⠼');
    final next = _window(title: 'Building ⠴');

    expect(first, isNot(next));
    expect(first.hasSameSceneDescriptionAs(next), isTrue);
  });

  test('scene comparison includes texture geometry', () {
    final first = _window(title: 'Building');
    final resized = _window(title: 'Building', width: 1280);

    expect(first.hasSameSceneDescriptionAs(resized), isFalse);
  });

  test('live placement scene role excludes texture geometry', () {
    final first = _window(title: 'Building');
    final resized = _window(title: 'Building', width: 1280);
    final repinned = _window(title: 'Building', width: 1280, pinned: true);

    expect(first.hasSameStaticSceneRoleAs(resized), isTrue);
    expect(first.hasSameStaticSceneRoleAs(repinned), isFalse);
  });

  test(
    'input-method candidates are compositor UI, not desktop applications',
    () {
      final popup = _window(
        title: 'Input method',
        appId: 'denia-systemui-input-method',
      );

      expect(popup.isInputMethodPopup, isTrue);
      expect(popup.isSystemUi, isTrue);
      expect(popup.isUserApp, isFalse);
    },
  );
}

DenialWindow _window({
  required String title,
  int width = 1920,
  bool pinned = false,
  String appId = 'kitty',
}) {
  return DenialWindow(
    objectId: 1,
    objectKind: 'root_surface',
    surfaceId: 1,
    windowId: 11,
    textureId: 101,
    title: title,
    appId: appId,
    width: width,
    height: 1080,
    surfaceX: 0,
    surfaceY: 0,
    surfaceWidth: width.toDouble(),
    surfaceHeight: 1080,
    textureSourceX: 0,
    textureSourceY: 0,
    textureSourceWidth: width.toDouble(),
    textureSourceHeight: 1080,
    geometryX: 100,
    geometryY: 80,
    geometryWidth: width.toDouble(),
    geometryHeight: 1080,
    monitorId: 1,
    transform: 0,
    scale120: 120,
    pinned: pinned,
  );
}
