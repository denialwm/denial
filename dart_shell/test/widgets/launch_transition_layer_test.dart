import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/app_launch_request.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/theme/glass_configuration.dart';
import 'package:denial_dart_shell/src/widgets/app_icon.dart';
import 'package:denial_dart_shell/src/widgets/launch_transition_layer.dart';
import 'package:denial_dart_shell/src/widgets/window_hero.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('running app grows its retained live surface from the icon', (
    tester,
  ) async {
    const source = Rect.fromLTWH(74, 110, 85, 85);
    const layerOffset = Offset(20, 30);
    final request = _request(existing: true, source: source);
    final completed = <(int, int)>[];
    await tester.pumpWidget(
      _harness(
        Stack(
          children: [
            Positioned(
              left: layerOffset.dx,
              top: layerOffset.dy,
              width: 360,
              height: 720,
              child: Stack(
                children: [
                  LaunchTransitionLayer(
                    request: request,
                    window: _window,
                    onCompleted: (id, object) => completed.add((id, object)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.byType(AppIconImage), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(Opacity), findsNothing);
    final surfaceFinder = find.byType(WindowSurface);
    final surface = tester.widget(surfaceFinder);
    final render = tester.renderObject<RenderBox>(surfaceFinder);
    Rect visualRect() => MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
    expect(visualRect(), rectMoreOrLessEquals(source));
    expect(render.size, const Size(360, 720));
    await tester.pump(const Duration(milliseconds: 100));
    expect(visualRect().width, greaterThan(source.width));
    expect(visualRect().width, lessThan(360));
    expect(tester.widget(surfaceFinder), same(surface));
    expect(render.size, const Size(360, 720));
    expect(completed, isEmpty);
    await tester.pumpAndSettle();
    expect(
      visualRect(),
      rectMoreOrLessEquals(layerOffset & const Size(360, 720)),
    );
    expect(completed, [(7, 1)]);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, [(7, 1)]);
  });
}

AppLaunchRequest _request({required bool existing, Rect? source}) =>
    AppLaunchRequest(
      requestId: 7,
      appName: 'Test app',
      iconPath: null,
      expectedAppIds: ['test'],
      existingObjectIds: existing ? [1] : [],
      targetObjectId: existing ? 1 : null,
      sourceRect: source,
    );

Widget _harness(Widget child) => ProviderScope(
  child: DenialLocalizationScope(
    locale: const Locale('en'),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: ShellTheme(
          data: const ShellThemeData(
            transparencyMode: ShellTransparencyMode.glass,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 400, height: 800, child: child),
          ),
        ),
      ),
    ),
  ),
);

const _window = DenialWindow(
  objectId: 1,
  objectKind: 'xdg_toplevel',
  surfaceId: 1,
  windowId: 1,
  textureId: 1,
  title: 'Test app',
  appId: 'test',
  width: 400,
  height: 800,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 400,
  surfaceHeight: 800,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 400,
  textureSourceHeight: 800,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 400,
  geometryHeight: 800,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);
