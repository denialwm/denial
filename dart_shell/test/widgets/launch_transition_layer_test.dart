import 'dart:io';

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
  testWidgets(
    'cold launch retains full-size app layout and icon through zoom and reveal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = Directory.systemTemp.createTempSync('denial-launch-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final icon = File('${directory.path}/icon.svg')
        ..writeAsStringSync(
          '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><path fill="red" d="M0 0H64V64H0Z"/></svg>',
        );
      await tester.runAsync(
        () => DesktopAppSvgLoader(icon.path).loadBytes(null),
      );
      final request = _request(existing: false, iconPath: icon.path);
      final completed = <(int, int)>[];
      Widget launch(DenialWindow? window) => _harness(
        Stack(
          children: [
            LaunchTransitionLayer(
              request: request,
              window: window,
              onCompleted: (id, object) => completed.add((id, object)),
            ),
          ],
        ),
      );
      await tester.pumpWidget(launch(null));
      await tester.pump();
      final iconFinder = find.byType(AppIconImage);
      final iconElement = iconFinder.evaluate().single;
      final iconSize = tester.getSize(iconFinder);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 8));
        expect(tester.getSize(iconFinder), iconSize);
      }
      expect(completed, isEmpty);
      await tester.pumpWidget(launch(_window));
      expect(iconFinder.evaluate().single, same(iconElement));
      final surface = find.byType(WindowSurface);
      final surfaceWidget = tester.widget(surface);
      final builds = <String>[];
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, _) =>
          builds.add(element.widget.runtimeType.toString());
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 8));
        expect(tester.getSize(surface), const Size(400, 800));
        expect(tester.widget(surface), same(surfaceWidget));
        expect(tester.getSize(iconFinder), iconSize);
      }
      expect(builds, isEmpty);
      expect(completed, [(7, 1)]);
      expect(tester.takeException(), isNull);
    },
  );

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

AppLaunchRequest _request({
  required bool existing,
  Rect? source,
  String? iconPath,
}) => AppLaunchRequest(
  requestId: 7,
  appName: 'Test app',
  iconPath: iconPath,
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
