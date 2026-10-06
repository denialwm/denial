import 'package:denial_dart_shell/src/desktop/desktop_input_layout_publisher.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clips a client input region and maps its source coordinates', () {
    final clipped = desktopClipInputGeometryToRect(
      rect: const Rect.fromLTWH(50, 20, 200, 100),
      sourceRect: const Rect.fromLTWH(10, 5, 400, 200),
      clipRect: const Rect.fromLTWH(100, 0, 100, 200),
    );

    expect(clipped?.rect, const Rect.fromLTWH(100, 20, 100, 100));
    expect(clipped?.sourceRect, const Rect.fromLTWH(110, 5, 200, 200));
  });

  test('drops a client input region outside its output', () {
    expect(
      desktopClipInputGeometryToRect(
        rect: const Rect.fromLTWH(0, 0, 50, 50),
        sourceRect: const Rect.fromLTWH(0, 0, 50, 50),
        clipRect: const Rect.fromLTWH(100, 0, 100, 100),
      ),
      isNull,
    );
  });

  test('layer roots and popups publish front-to-back native routes', () {
    final regions = desktopLayerInputRegions(<DenialWindow>[
      _layerSurface(),
    ], zBand: 100);

    expect(regions, hasLength(2));
    expect(regions[0].targetSurfaceId, 11);
    expect(regions[0].rect, const Rect.fromLTWH(95, 60, 30, 20));
    expect(regions[0].sourceRect, const Rect.fromLTWH(0, 0, 30, 20));
    expect(regions[0].z, 102);
    expect(regions[1].targetSurfaceId, 10);
    expect(regions[1].rect, const Rect.fromLTWH(20, 30, 100, 50));
    expect(regions[1].sourceRect, const Rect.fromLTWH(5, 10, 100, 50));
    expect(regions[1].z, 101);
    expect(regions.every((region) => region.geometryLocked), isTrue);
    expect(
      desktopLayerInputRegions(
        <DenialWindow>[_layerSurface()],
        zBand: 100,
        enabled: false,
      ),
      isEmpty,
    );
  });
}

DenialWindow _layerSurface() => const DenialWindow(
  objectId: 10,
  objectKind: 'layer_surface',
  surfaceId: 10,
  windowId: 10,
  textureId: 10,
  title: 'panel',
  appId: 'panel',
  width: 100,
  height: 50,
  surfaceX: 5,
  surfaceY: 10,
  surfaceWidth: 100,
  surfaceHeight: 50,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 100,
  textureSourceHeight: 50,
  geometryX: 20,
  geometryY: 30,
  geometryWidth: 100,
  geometryHeight: 50,
  monitorId: 1,
  transform: 0,
  scale120: 120,
  contentX: 5,
  contentY: 10,
  contentWidth: 100,
  contentHeight: 50,
  contentKind: DenialWindowContentKind.layerShellTop,
  surfaceLayers: <DenialSurfaceLayer>[
    DenialSurfaceLayer(
      surfaceId: 10,
      parentSurfaceId: 0,
      popupRootSurfaceId: 0,
      role: DenialSurfaceRole.root,
      textureId: 10,
      width: 100,
      height: 50,
      surfaceX: 5,
      surfaceY: 10,
      surfaceWidth: 100,
      surfaceHeight: 50,
      textureSourceX: 0,
      textureSourceY: 0,
      textureSourceWidth: 100,
      textureSourceHeight: 50,
      transform: 0,
      scale120: 120,
      compositionOrder: 0,
    ),
    DenialSurfaceLayer(
      surfaceId: 11,
      parentSurfaceId: 10,
      popupRootSurfaceId: 11,
      role: DenialSurfaceRole.popup,
      textureId: 11,
      width: 30,
      height: 20,
      surfaceX: 80,
      surfaceY: 40,
      surfaceWidth: 30,
      surfaceHeight: 20,
      textureSourceX: 0,
      textureSourceY: 0,
      textureSourceWidth: 30,
      textureSourceHeight: 20,
      transform: 0,
      scale120: 120,
      compositionOrder: 1,
    ),
  ],
);
