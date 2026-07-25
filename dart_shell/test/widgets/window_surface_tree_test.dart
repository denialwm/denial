import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/widgets/window_hero.dart';
import 'package:denial_dart_shell/src/widgets/window_surface_tree.dart';
import 'package:denial_dart_shell/src/widgets/window_texture_rect.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main visibility excludes popup textures', () {
    final window = _window(
      serverSideDecorated: true,
      surfaceLayers: <DenialSurfaceLayer>[
        _layer(surfaceId: 1),
        _layer(surfaceId: 2, popupRootSurfaceId: 2),
      ],
    );

    expect(window.mainVisibleSurfaceIds, <int>[1]);
    expect(window.visibleSurfaceIds, <int>[1, 2]);
  });

  test('only a fully covering opaque root skips backdrop blur', () {
    final opaqueWindow = _window(
      serverSideDecorated: true,
      surfaceLayers: <DenialSurfaceLayer>[_layer(surfaceId: 1, opaque: true)],
    );
    final transparentWindow = _window(
      serverSideDecorated: true,
      surfaceLayers: <DenialSurfaceLayer>[_layer(surfaceId: 1)],
    );

    expect(opaqueWindow.isOpaque, isTrue);
    expect(transparentWindow.isOpaque, isFalse);
  });

  testWidgets('surface opacity is applied to the complete texture layer', (
    tester,
  ) async {
    const layer = DenialSurfaceLayer(
      surfaceId: 1,
      parentSurfaceId: 0,
      popupRootSurfaceId: 0,
      role: DenialSurfaceRole.root,
      textureId: 7,
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
      transform: 0,
      scale120: 120,
      compositionOrder: 0,
      opacity: 0.4,
    );

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 100,
          height: 80,
          child: SurfaceLayerTexture(layer: layer),
        ),
      ),
    );

    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.4);
  });

  testWidgets('client-decorated previews suppress server radius and border', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 100,
            height: 80,
            child: WindowSurface(
              window: _window(serverSideDecorated: false),
              radius: 20,
              borderColor: const Color(0xffffffff),
            ),
          ),
        ),
      ),
    );

    final texture = tester.widget<WindowTextureRect>(
      find.byType(WindowTextureRect),
    );
    expect(texture.borderRadius, BorderRadius.zero);
    expect(find.byType(Stack), findsNothing);
  });
}

DenialWindow _window({
  required bool serverSideDecorated,
  List<DenialSurfaceLayer> surfaceLayers = const <DenialSurfaceLayer>[],
}) {
  return DenialWindow(
    objectId: 1,
    objectKind: 'root_surface',
    surfaceId: 1,
    windowId: 1,
    textureId: 7,
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
    serverSideDecorated: serverSideDecorated,
    surfaceLayers: surfaceLayers,
  );
}

DenialSurfaceLayer _layer({
  required int surfaceId,
  int popupRootSurfaceId = 0,
  bool opaque = false,
}) {
  return DenialSurfaceLayer(
    surfaceId: surfaceId,
    parentSurfaceId: 0,
    popupRootSurfaceId: popupRootSurfaceId,
    role: popupRootSurfaceId == 0
        ? DenialSurfaceRole.root
        : DenialSurfaceRole.popup,
    textureId: surfaceId + 10,
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
    transform: 0,
    scale120: 120,
    compositionOrder: surfaceId,
    opaque: opaque,
  );
}
