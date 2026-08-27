import 'dart:async';

import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:denial_dart_shell/src/widgets/shell_cursor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cursor artwork priority never combines theme and client surface', () {
    ShellCursorArtworkSource resolve({
      bool positioned = true,
      bool visible = true,
      bool hidden = false,
      bool client = false,
      bool drag = false,
    }) => shellCursorArtworkSource(
      hasPosition: positioned,
      themedCursorVisible: visible,
      cursorHidden: hidden,
      clientSurfaceRequested: client,
      dragActive: drag,
    );

    expect(resolve(), ShellCursorArtworkSource.themed);
    expect(resolve(client: true), ShellCursorArtworkSource.clientSurface);
    expect(resolve(client: true, drag: true), ShellCursorArtworkSource.themed);
    expect(resolve(client: true, hidden: true), ShellCursorArtworkSource.none);
    expect(resolve(positioned: false), ShellCursorArtworkSource.none);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('large animated themes use the same cursor compatibility path', (
    tester,
  ) async {
    final shapes = StreamController<String>.broadcast(sync: true);
    final positions = StreamController<Offset>.broadcast(sync: true);
    addTearDown(shapes.close);
    addTearDown(positions.close);

    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _CursorTestAssetBundle(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ShellCursorHost(
            theme: _animatedCursorTestTheme,
            cursorSize: 64,
            displayLayout: _cursorLayout(1),
            platformCursorShapes: shapes.stream,
            platformCursorPositions: positions.stream,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    positions.add(const Offset(100, 100));
    shapes.add('nw-resize');
    await tester.pump();

    AssetImage cursorImage() {
      return tester.widget<Image>(find.byType(Image)).image as AssetImage;
    }

    expect(cursorImage().assetName, endsWith('/diagonal_nwse/00.png'));
    expect(tester.widget<Image>(find.byType(Image)).width, 64);
    expect(tester.widget<Image>(find.byType(Image)).height, 64);

    await tester.pump(const Duration(milliseconds: 41));
    expect(cursorImage().assetName, endsWith('/diagonal_nwse/01.png'));

    await tester.pump(const Duration(milliseconds: 41));
    expect(cursorImage().assetName, endsWith('/diagonal_nwse/00.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Flutter cursor sessions request Rust authority before artwork changes',
    (tester) async {
      final shapes = StreamController<String>.broadcast(sync: true);
      final requests = <MethodCall>[];
      addTearDown(shapes.close);
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        'flutter/mousecursor',
        (message) async {
          requests.add(const StandardMethodCodec().decodeMethodCall(message));
          return const StandardMethodCodec().encodeSuccessEnvelope(null);
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMessageHandler(
          'flutter/mousecursor',
          null,
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ShellCursorHost(
            theme: ShellCursorThemes.bibataModernIce,
            platformCursorShapes: shapes.stream,
            child: MouseRegion(
              cursor: ShellMouseCursors.link,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      shapes.add('default');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(100, 80));
      await mouse.moveTo(const Offset(101, 80));
      await tester.pump();

      AssetImage cursorImage() {
        return tester.widget<Image>(find.byType(Image)).image as AssetImage;
      }

      expect(
        requests,
        contains(
          isA<MethodCall>()
              .having((call) => call.method, 'method', 'activateSystemCursor')
              .having(
                (call) => (call.arguments as Map<Object?, Object?>)['kind'],
                'kind',
                'click',
              ),
        ),
      );
      expect(cursorImage().assetName, endsWith('/normal/00.png'));

      shapes.add('pointer');
      await tester.pump();
      expect(cursorImage().assetName, endsWith('/link/00.png'));
    },
  );

  testWidgets('native position authority survives Flutter pointer removal', (
    tester,
  ) async {
    final shapes = StreamController<String>.broadcast(sync: true);
    final positions = StreamController<Offset>.broadcast(sync: true);
    addTearDown(shapes.close);
    addTearDown(positions.close);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ShellCursorHost(
          theme: ShellCursorThemes.bibataModernIce,
          platformCursorShapes: shapes.stream,
          platformCursorPositions: positions.stream,
          child: const SizedBox.expand(),
        ),
      ),
    );
    shapes.add('default');
    positions.add(const Offset(100, 80));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 80));
    await mouse.removePointer();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('display scaling preserves the configured physical cursor size', (
    tester,
  ) async {
    final positions = StreamController<Offset>.broadcast(sync: true);
    addTearDown(positions.close);

    Widget host(double outputScale) => Directionality(
      textDirection: TextDirection.ltr,
      child: ShellCursorHost(
        theme: ShellCursorThemes.bibataModernIce,
        cursorSize: 32,
        displayLayout: _cursorLayout(outputScale),
        platformCursorPositions: positions.stream,
        child: const SizedBox.expand(),
      ),
    );

    await tester.pumpWidget(host(1));
    positions.add(const Offset(100, 80));
    await tester.pump();

    Image cursorImage() => tester.widget<Image>(find.byType(Image));
    Offset cursorPosition() => tester.getTopLeft(find.byType(Image));

    expect(cursorImage().width, 32);
    expect(cursorImage().height, 32);
    expect(cursorPosition(), const Offset(94, 78));

    await tester.pumpWidget(host(2));
    expect(cursorImage().width, 16);
    expect(cursorImage().height, 16);
    expect(cursorImage().width! * 2, 32);
    expect(cursorPosition(), const Offset(97, 79));

    await tester.pumpWidget(host(1.5));
    expect(cursorImage().width! * 1.5, closeTo(32, 0.001));
    expect(cursorImage().height! * 1.5, closeTo(32, 0.001));
  });

  testWidgets('cross-output motion rebuilds artwork for the new scale', (
    tester,
  ) async {
    final positions = StreamController<Offset>.broadcast(sync: true);
    addTearDown(positions.close);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ShellCursorHost(
          theme: ShellCursorThemes.bibataModernIce,
          cursorSize: 32,
          displayLayout: _twoScaleCursorLayout(),
          platformCursorPositions: positions.stream,
          child: const SizedBox.expand(),
        ),
      ),
    );
    positions.add(const Offset(100, 80));
    await tester.pump();
    final firstArtwork = tester.widget<Image>(find.byType(Image));
    expect(firstArtwork.width, 32);

    positions.add(const Offset(250, 80));
    await tester.pump();

    expect(tester.widget<Image>(find.byType(Image)), isNot(same(firstArtwork)));
    expect(tester.widget<Image>(find.byType(Image)).width, 16);
    expect(tester.getTopLeft(find.byType(Image)), const Offset(247, 79));
  });
}

const _animatedCursorTestTheme = ShellCursorThemeData(
  id: 'animated_cursor_test',
  label: 'Animated cursor test',
  author: 'Denial',
  assetRoot: 'test/cursors',
  roles: <ShellCursorKind, ShellCursorRoleData>{
    ShellCursorKind.normal: ShellCursorRoleData(
      assetDirectory: 'normal',
      size: Size(64, 64),
      hotspot: Offset(18, 9),
      frameCount: 2,
      frameDuration: Duration(milliseconds: 40),
    ),
    ShellCursorKind.diagonalNwSeResize: ShellCursorRoleData(
      assetDirectory: 'diagonal_nwse',
      size: Size(64, 64),
      hotspot: Offset(32, 32),
      frameCount: 2,
      frameDuration: Duration(milliseconds: 40),
    ),
  },
);

class _CursorTestAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) {
    if (key.startsWith('test/cursors/')) {
      return rootBundle.load('assets/cursors/bibata_modern_ice/normal/00.png');
    }
    return rootBundle.load(key);
  }
}

DisplayLayout _cursorLayout(double scale) {
  return DisplayLayout(
    epoch: 1,
    globalOrigin: Offset.zero,
    logicalSize: const Size(200, 120),
    pixelSize: Size(200 * scale, 120 * scale),
    engineScale: scale,
    tickerMonitorId: 1,
    systemBarMonitorId: 1,
    systemBarSide: SystemBarSide.top,
    outputs: <DisplayOutput>[
      DisplayOutput(
        monitorId: 1,
        name: 'test-output',
        logicalRect: const Rect.fromLTWH(0, 0, 200, 120),
        pixelSize: Size(200 * scale, 120 * scale),
        scale: scale,
        refreshRate: 60,
      ),
    ],
  );
}

DisplayLayout _twoScaleCursorLayout() {
  return const DisplayLayout(
    epoch: 1,
    globalOrigin: Offset.zero,
    logicalSize: Size(400, 120),
    pixelSize: Size(600, 240),
    engineScale: 1,
    tickerMonitorId: 1,
    systemBarMonitorId: 1,
    systemBarSide: SystemBarSide.top,
    outputs: <DisplayOutput>[
      DisplayOutput(
        monitorId: 1,
        name: 'scale-1',
        logicalRect: Rect.fromLTWH(0, 0, 200, 120),
        pixelSize: Size(200, 120),
        scale: 1,
        refreshRate: 60,
      ),
      DisplayOutput(
        monitorId: 2,
        name: 'scale-2',
        logicalRect: Rect.fromLTWH(200, 0, 200, 120),
        pixelSize: Size(400, 240),
        scale: 2,
        refreshRate: 60,
      ),
    ],
  );
}
