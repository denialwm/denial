import 'package:denial_dart_shell/src/models/hypr_window.dart';
import 'package:denial_dart_shell/src/widgets/window_hero.dart';
import 'package:denial_dart_shell/src/widgets/window_surface_tree.dart';
import 'package:denial_dart_shell/src/widgets/window_texture_rect.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('surface opacity is applied to the complete texture layer',
      (tester) async {
    const layer = HyprSurfaceLayer(
      surfaceId: 1,
      parentSurfaceId: 0,
      popupRootSurfaceId: 0,
      role: HyprSurfaceRole.root,
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

  testWidgets('client-decorated previews suppress server radius and border',
      (tester) async {
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

HyprWindow _window({required bool serverSideDecorated}) {
  return HyprWindow(
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
  );
}
