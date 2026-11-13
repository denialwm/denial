import 'package:denial_flutter_sdk/src/models/denial_window.dart';
import 'package:denial_flutter_sdk/src/state/front_after_close.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final app = _window(1);
  final dialog = _window(2, parent: 1);
  final nested = _window(3, parent: 2);

  test('a closed dialog hands the front back to its app', () {
    expect(frontAfterClose(dialog, [app]), app);
  });

  test('a closed nested dialog hands it to the dialog it opened over', () {
    expect(frontAfterClose(nested, [app, dialog]), dialog);
  });

  test('a minimized parent gives it to its own parent', () {
    final minimized = _window(2, parent: 1, minimized: true);
    expect(frontAfterClose(nested, [app, minimized]), app);
  });

  test('a closed app without a parent leaves nothing in front', () {
    expect(frontAfterClose(app, [dialog]), isNull);
    expect(frontAfterClose(null, [app]), isNull);
  });

  test('a parent that closed too leaves nothing in front', () {
    expect(frontAfterClose(dialog, const []), isNull);
  });
}

DenialWindow _window(int id, {int? parent, bool minimized = false}) =>
    DenialWindow(
      objectId: id,
      objectKind: 'xdg_toplevel',
      surfaceId: id,
      windowId: id,
      textureId: id,
      title: 'app',
      appId: 'org.example.app',
      width: 100,
      height: 100,
      surfaceX: 0,
      surfaceY: 0,
      surfaceWidth: 100,
      surfaceHeight: 100,
      textureSourceX: 0,
      textureSourceY: 0,
      textureSourceWidth: 100,
      textureSourceHeight: 100,
      geometryX: 0,
      geometryY: 0,
      geometryWidth: 100,
      geometryHeight: 100,
      monitorId: 1,
      transientParentObjectId: parent,
      minimized: minimized,
      transform: 0,
      scale120: 120,
    );
