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

  test('window opacity class distinguishes content from border alpha', () {
    final opaqueWindow = _window(
      serverSideDecorated: true,
      surfaceLayers: <DenialSurfaceLayer>[_layer(surfaceId: 1, opaque: true)],
      opacityClass: DenialWindowOpacityClass.fullyOpaque,
    );
    final transparentWindow = _window(
      serverSideDecorated: true,
      surfaceLayers: <DenialSurfaceLayer>[_layer(surfaceId: 1)],
    );
    final borderAlphaWindow = _window(
      serverSideDecorated: false,
      surfaceLayers: <DenialSurfaceLayer>[_layer(surfaceId: 1)],
      opacityClass: DenialWindowOpacityClass.borderAlphaOnly,
    );

    expect(opaqueWindow.isOpaque, isTrue);
    expect(transparentWindow.isOpaque, isFalse);
    expect(transparentWindow.isContentTranslucent, isTrue);
    expect(borderAlphaWindow.isOpaque, isFalse);
    expect(borderAlphaWindow.isContentTranslucent, isFalse);
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

  testWidgets('fractional-scale buffers retain one logical pixel per DPR', (
    tester,
  ) async {
    final layer = _fractionalLayer();

    await _pumpPositionedLayer(tester, layer: layer);

    final texture = find.byType(Texture);
    expect(tester.getSize(texture), const Size(602 / 1.5, 452 / 1.5));
    expect(tester.widget<Texture>(texture).filterQuality, FilterQuality.none);
    final textureOrigin = tester.getTopLeft(texture);
    expect(textureOrigin.dx * 1.5, closeTo(151, 0.001));
    expect(textureOrigin.dy * 1.5, closeTo(61, 0.001));
  });

  testWidgets('integer-scale buffers use bilinear fractional reduction', (
    tester,
  ) async {
    final layer = _fractionalLayer(width: 802, height: 602);

    await _pumpPositionedLayer(tester, layer: layer);

    final texture = find.byType(Texture);
    expect(tester.getSize(texture), const Size(401, 301));
    expect(tester.widget<Texture>(texture).filterQuality, FilterQuality.low);
  });

  testWidgets('smoothed transforms keep the ordinary fitted texture path', (
    tester,
  ) async {
    final layer = _fractionalLayer();

    await _pumpPositionedLayer(
      tester,
      layer: layer,
      filterQuality: FilterQuality.medium,
    );

    final texture = find.byType(Texture);
    expect(tester.getSize(texture), const Size(401, 301));
    expect(tester.getTopLeft(texture), const Offset(101, 41));
  });

  testWidgets('undersized buffers are fitted instead of exposing an edge', (
    tester,
  ) async {
    final layer = _fractionalLayer(width: 601, height: 451);

    await _pumpPositionedLayer(tester, layer: layer);

    final texture = find.byType(Texture);
    expect(tester.getSize(texture), const Size(401, 301));
    expect(tester.getTopLeft(texture), const Offset(101, 41));
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

DenialSurfaceLayer _fractionalLayer({int width = 602, int height = 452}) {
  return DenialSurfaceLayer(
    surfaceId: 1,
    parentSurfaceId: 0,
    popupRootSurfaceId: 0,
    role: DenialSurfaceRole.root,
    textureId: 7,
    width: width,
    height: height,
    surfaceX: 0,
    surfaceY: 0,
    surfaceWidth: 401,
    surfaceHeight: 301,
    textureSourceX: 0,
    textureSourceY: 0,
    textureSourceWidth: width.toDouble(),
    textureSourceHeight: height.toDouble(),
    transform: 0,
    scale120: 120,
    compositionOrder: 0,
  );
}

Future<void> _pumpPositionedLayer(
  WidgetTester tester, {
  required DenialSurfaceLayer layer,
  FilterQuality filterQuality = FilterQuality.none,
}) {
  tester.view.devicePixelRatio = 1.5;
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(devicePixelRatio: 1.5),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              left: 101,
              top: 41,
              width: 401,
              height: 301,
              child: SurfaceLayerTexture(
                layer: layer,
                filterQuality: filterQuality,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

DenialWindow _window({
  required bool serverSideDecorated,
  List<DenialSurfaceLayer> surfaceLayers = const <DenialSurfaceLayer>[],
  DenialWindowOpacityClass opacityClass =
      DenialWindowOpacityClass.contentTranslucent,
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
    opacityClass: opacityClass,
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
