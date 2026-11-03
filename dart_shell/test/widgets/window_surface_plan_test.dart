import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

DenialSurfaceLayer layer(
  int id, {
  bool opaque = true,
  double opacity = 1,
  double width = 100,
  double x = 0,
  double y = 0,
  double height = 80,
  bool popup = false,
}) => DenialSurfaceLayer(
  surfaceId: id,
  parentSurfaceId: id == 1 ? 0 : 1,
  popupRootSurfaceId: popup ? id : 0,
  role: popup
      ? DenialSurfaceRole.popup
      : id == 1
      ? DenialSurfaceRole.root
      : DenialSurfaceRole.subsurface,
  textureId: id,
  width: 100,
  height: 80,
  surfaceX: x,
  surfaceY: y,
  surfaceWidth: width,
  surfaceHeight: height,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 100,
  textureSourceHeight: 80,
  transform: 0,
  scale120: 120,
  compositionOrder: id,
  opaque: opaque,
  opacity: opacity,
);

DenialWindow window(
  List<DenialSurfaceLayer> layers, {
  DenialClientTexture? client,
}) => DenialWindow(
  objectId: 1,
  objectKind: 'root_surface',
  surfaceId: 1,
  windowId: 1,
  textureId: 1,
  title: '',
  appId: 'test',
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
  surfaceLayers: layers,
  clientTexture: client,
);

void main() {
  test('native client image selects one texture and preserves input and popup tree', () {
    const client = DenialClientTexture(
      textureId: 1 << 62,
      width: 126,
      height: 101,
      sourceWidth: 125.25,
      sourceHeight: 100.5,
    );
    final app = window([
      layer(1, opaque: false),
      layer(2, opacity: 0.6),
      layer(3, popup: true),
    ], client: client);
    final texture = singleWindowPlaneTexture(app)!;
    expect(texture.id, client.textureId);
    expect(texture.bufferSize, const Size(126, 101));
    expect(texture.source, const Rect.fromLTWH(0, 0, 125.25, 100.5));
    expect(texture.opacity, 1);
    expect(texture.transform, 0);
    expect(app.mainVisibleSurfaceIds, [1, 2]);
    expect(app.popupSurfaceLayers.single.surfaceId, 3);
    final original = window(app.surfaceLayers);
    expect(singleWindowPlaneTexture(original), isNull);
    expect(app.hasSameSceneDescriptionAs(original), isFalse);
  });

  test(
    'opaque child selects direct texture and stops sampling covered root',
    () {
      final app = window([layer(1), layer(2)]);
      expect(singleWindowPlaneTexture(app)!.id, 2);
      expect(app.mainVisibleSurfaceIds, [2]);
      expect(app.surfaceLayers.map((layer) => layer.surfaceId), [1, 2]);
    },
  );
  test('partial or translucent children keep the composed path', () {
    for (final child in [
      layer(2, opaque: false),
      layer(2, opacity: 0.5),
      layer(2, width: 50),
    ]) {
      final app = window([layer(1), child]);
      expect(singleWindowPlaneTexture(app), isNull);
      expect(app.mainVisibleSurfaceIds, [1, 2]);
    }
  });
  test('opaque base with interior children can draw directly', () {
    bool direct(List<DenialSurfaceLayer> layers, {bool backdrop = false}) {
      final app = window(layers);
      return canDrawWindowLayersDirectly(
        window: app,
        layers: app.paintedMainSurfaceLayers,
        content: const Rect.fromLTWH(1, 1, 100, 80),
        radius: 8,
        frameWidth: 1,
        presentationScale: 1,
        hasBackdrop: backdrop,
      );
    }

    final interior = layer(2, x: 12, y: 12, width: 40, height: 40);
    expect(direct([layer(1), interior]), isTrue);
    expect(direct([layer(1, opaque: false), interior]), isFalse);
    expect(direct([layer(1), interior], backdrop: true), isFalse);
    expect(direct([layer(1), layer(2, width: 40)]), isFalse);
    expect(
      direct([
        layer(1),
        layer(2, x: 12, y: 12, width: 40, height: 40, opacity: 0.5),
      ]),
      isTrue,
    );
  });

  test('popups do not occlude the main window and retain sampling', () {
    final app = window([layer(1), layer(2, popup: true)]);
    expect(singleWindowPlaneTexture(app)!.id, 1);
    expect(app.mainVisibleSurfaceIds, [1]);
    expect(app.visibleSurfaceIds, [1, 2]);
  });
  test('uncovering or changing alpha restores lower-layer sampling', () {
    final covered = window([layer(1), layer(2)]);
    final uncovered = window([layer(1), layer(2, opacity: 0.5)]);
    expect(covered.mainVisibleSurfaceIds, [2]);
    expect(uncovered.mainVisibleSurfaceIds, [1, 2]);
    expect(singleWindowPlaneTexture(uncovered), isNull);
  });
}
