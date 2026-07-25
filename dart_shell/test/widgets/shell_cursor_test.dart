import 'dart:async';

import 'package:denial_dart_shell/src/models/denial_drag_icon.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:denial_dart_shell/src/widgets/shell_cursor.dart';
import 'package:denial_dart_shell/src/widgets/window_surface_tree.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Bibata covers every static role with its upstream hotspot', () {
    const theme = ShellCursorThemes.bibataModernIce;
    final expectedHotspots = <ShellCursorKind, Offset>{
      ShellCursorKind.normal: const Offset(6, 2),
      ShellCursorKind.help: const Offset(5, 10),
      ShellCursorKind.working: const Offset(6, 2),
      ShellCursorKind.text: const Offset(16, 16),
      ShellCursorKind.link: const Offset(14, 2),
      ShellCursorKind.busy: const Offset(16, 16),
      ShellCursorKind.precision: const Offset(16, 16),
      ShellCursorKind.handwriting: const Offset(5, 26),
      ShellCursorKind.unavailable: const Offset(16, 16),
      ShellCursorKind.verticalResize: const Offset(16, 16),
      ShellCursorKind.horizontalResize: const Offset(16, 16),
      ShellCursorKind.diagonalNwSeResize: const Offset(16, 16),
      ShellCursorKind.diagonalNeSwResize: const Offset(16, 16),
      ShellCursorKind.move: const Offset(16, 16),
      ShellCursorKind.alternate: const Offset(12, 8),
      ShellCursorKind.person: const Offset(4, 1),
      ShellCursorKind.pin: const Offset(4, 1),
    };

    expect(theme.roles.keys.toSet(), ShellCursorKind.values.toSet());
    expect(expectedHotspots.keys.toSet(), ShellCursorKind.values.toSet());
    for (final kind in ShellCursorKind.values) {
      final role = theme.roleFor(kind);
      expect(role.size, const Size(32, 32), reason: kind.name);
      expect(role.hotspot, expectedHotspots[kind], reason: kind.name);
      expect(role.frameCount, 1, reason: kind.name);
      expect(role.frameDuration, Duration.zero, reason: kind.name);
      expect(role.isAnimated, isFalse, reason: kind.name);
    }
    expect(theme.assetPaths.length, ShellCursorKind.values.length);
    expect(ShellCursorThemes.all.first, same(theme));
    expect(ShellCursorThemes.find(theme.id), same(theme));
  });

  test('every Bibata frame is bundled', () async {
    const theme = ShellCursorThemes.bibataModernIce;

    for (final path in theme.assetPaths) {
      final data = await rootBundle.load(path);
      expect(data.lengthInBytes, greaterThan(0), reason: path);
    }
  });

  test('native and Flutter cursor aliases reach every cursor role', () {
    final shapes = <ShellCursorKind, List<String>>{
      ShellCursorKind.normal: <String>[
        'default',
        'basic',
        'surface',
        'context-menu',
      ],
      ShellCursorKind.help: <String>['help', 'question_arrow', 'dnd-ask'],
      ShellCursorKind.working: <String>[
        'progress',
        'working',
        'left_ptr_watch',
      ],
      ShellCursorKind.text: <String>['text', 'vertical-text', 'xterm'],
      ShellCursorKind.link: <String>['pointer', 'hand2', 'click'],
      ShellCursorKind.busy: <String>['wait', 'watch', 'busy'],
      ShellCursorKind.precision: <String>[
        'cell',
        'crosshair',
        'precise',
        'zoom-in',
        'zoomOut',
      ],
      ShellCursorKind.handwriting: <String>['handwriting', 'pencil', 'nwpen'],
      ShellCursorKind.unavailable: <String>[
        'invalid',
        'no-drop',
        'not-allowed',
        'forbidden',
      ],
      ShellCursorKind.verticalResize: <String>[
        'n-resize',
        's-resize',
        'ns-resize',
        'row-resize',
        'top_side',
        'bottom_side',
        'resizeUpDown',
        'resizeRow',
      ],
      ShellCursorKind.horizontalResize: <String>[
        'e-resize',
        'w-resize',
        'ew-resize',
        'col-resize',
        'left_side',
        'right_side',
        'resizeLeftRight',
        'resizeColumn',
      ],
      ShellCursorKind.diagonalNwSeResize: <String>[
        'nw-resize',
        'se-resize',
        'nwse-resize',
        'top_left_corner',
        'bottom_right_corner',
        'resizeUpLeftDownRight',
      ],
      ShellCursorKind.diagonalNeSwResize: <String>[
        'ne-resize',
        'sw-resize',
        'nesw-resize',
        'top_right_corner',
        'bottom_left_corner',
        'resizeUpRightDownLeft',
      ],
      ShellCursorKind.move: <String>[
        'move',
        'grab',
        'grabbing',
        'all-scroll',
        'all-resize',
      ],
      ShellCursorKind.alternate: <String>[
        'alias',
        'copy',
        'alternate',
        'up_arrow',
      ],
      ShellCursorKind.person: <String>['person'],
      ShellCursorKind.pin: <String>['pin', 'location'],
    };

    expect(shapes.keys.toSet(), ShellCursorKind.values.toSet());
    for (final entry in shapes.entries) {
      for (final shape in entry.value) {
        expect(
          shellCursorKindForPlatformShape(shape),
          entry.key,
          reason: shape,
        );
      }
    }
  });

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

  testWidgets('drag icon follows native cursor positions and clears on drop', (
    tester,
  ) async {
    final positions = StreamController<Offset>.broadcast(sync: true);
    final dragIcons = StreamController<DenialDragIcon?>.broadcast(sync: true);
    addTearDown(positions.close);
    addTearDown(dragIcons.close);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          height: 300,
          child: ShellCursorHost(
            platformCursorPositions: positions.stream,
            platformDragIcons: dragIcons.stream,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    positions.add(const Offset(100, 80));
    dragIcons.add(_dragIcon());
    await tester.pump();

    Positioned dragPosition() => tester.widget<Positioned>(
      find
          .ancestor(
            of: find.byType(SurfaceLayerTexture),
            matching: find.byType(Positioned),
          )
          .first,
    );

    expect(find.byType(SurfaceLayerTexture), findsOneWidget);
    expect(dragPosition().left, 87.5);
    expect(dragPosition().top, 88.25);
    expect(dragPosition().width, 160);
    expect(dragPosition().height, 120);

    positions.add(const Offset(150, 110));
    await tester.pump();
    expect(dragPosition().left, 137.5);
    expect(dragPosition().top, 118.25);

    dragIcons.add(null);
    await tester.pump();
    expect(find.byType(SurfaceLayerTexture), findsNothing);
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

DenialDragIcon _dragIcon() {
  return const DenialDragIcon(
    sequence: 1,
    surfaceId: 0x200000004,
    offset: Offset(-12.5, 8.25),
    size: Size(160, 120),
    layer: DenialSurfaceLayer(
      surfaceId: 0x200000004,
      parentSurfaceId: 0,
      popupRootSurfaceId: 0,
      role: DenialSurfaceRole.root,
      textureId: 7,
      width: 320,
      height: 240,
      surfaceX: 0,
      surfaceY: 0,
      surfaceWidth: 160,
      surfaceHeight: 120,
      textureSourceX: 1,
      textureSourceY: 2,
      textureSourceWidth: 319,
      textureSourceHeight: 238,
      transform: 0,
      scale120: 120,
      compositionOrder: 0,
    ),
  );
}
