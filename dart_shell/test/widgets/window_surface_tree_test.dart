import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/widgets/window_surface_tree.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('owner output scale overrides the atlas device pixel ratio', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(devicePixelRatio: 2.0),
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
                  layer: _fractionalLayer,
                  presentationScale: 1.5,
                  pixelGridOrigin: Offset(101, 41),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final texture = find.byType(Texture);
    expect(tester.widget<Texture>(texture).filterQuality, FilterQuality.none);
    expect(tester.getSize(texture), const Size(602 / 1.5, 452 / 1.5));
    expect(tester.getTopLeft(texture), const Offset(101, 41));
  });
}

const _fractionalLayer = DenialSurfaceLayer(
  surfaceId: 1,
  parentSurfaceId: 0,
  popupRootSurfaceId: 0,
  role: DenialSurfaceRole.root,
  textureId: 7,
  width: 602,
  height: 452,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 401,
  surfaceHeight: 301,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 602,
  textureSourceHeight: 452,
  transform: 0,
  scale120: 180,
  compositionOrder: 0,
);
