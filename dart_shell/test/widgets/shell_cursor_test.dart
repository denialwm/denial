import 'dart:async';

import 'package:denial_dart_shell/src/models/denial_drag_icon.dart';
import 'package:denial_dart_shell/src/models/hypr_window.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:denial_dart_shell/src/widgets/shell_cursor.dart';
import 'package:denial_dart_shell/src/widgets/window_surface_tree.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full cursor theme covers every animated role and hotspot', () {
    const theme = ShellCursorThemes.yangyangXuanling;
    const frameDuration = Duration(microseconds: 83333);
    final expectedGeometry = <ShellCursorKind, ({Size size, Offset hotspot})>{
      ShellCursorKind.normal: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.help: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.working: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.text: (
        size: const Size(32, 32),
        hotspot: const Offset(4, 9),
      ),
      ShellCursorKind.link: (
        size: const Size(32, 32),
        hotspot: const Offset(4, 0),
      ),
      ShellCursorKind.busy: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.precision: (
        size: const Size(32, 32),
        hotspot: const Offset(5, 6),
      ),
      ShellCursorKind.handwriting: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.unavailable: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.verticalResize: (
        size: const Size(32, 32),
        hotspot: const Offset(15, 15),
      ),
      ShellCursorKind.horizontalResize: (
        size: const Size(32, 32),
        hotspot: const Offset(15, 15),
      ),
      ShellCursorKind.diagonalNwSeResize: (
        size: const Size(32, 32),
        hotspot: const Offset(15, 15),
      ),
      ShellCursorKind.diagonalNeSwResize: (
        size: const Size(32, 32),
        hotspot: const Offset(15, 15),
      ),
      ShellCursorKind.move: (
        size: const Size(32, 32),
        hotspot: const Offset(15, 15),
      ),
      ShellCursorKind.alternate: (
        size: const Size(32, 32),
        hotspot: const Offset(4, 0),
      ),
      ShellCursorKind.person: (
        size: const Size(32, 33),
        hotspot: Offset.zero,
      ),
      ShellCursorKind.pin: (
        size: const Size(32, 32),
        hotspot: Offset.zero,
      ),
    };

    expect(theme.roles.keys.toSet(), ShellCursorKind.values.toSet());
    expect(expectedGeometry.keys.toSet(), ShellCursorKind.values.toSet());
    for (final kind in ShellCursorKind.values) {
      final role = theme.roleFor(kind);
      final geometry = expectedGeometry[kind]!;
      expect(role.size, geometry.size, reason: kind.name);
      expect(role.hotspot, geometry.hotspot, reason: kind.name);
      expect(role.frameCount, 12, reason: kind.name);
      expect(role.frameDuration, frameDuration, reason: kind.name);
    }
    expect(theme.assetPaths.length, ShellCursorKind.values.length * 12);
  });

  test('every full-version animation frame is bundled', () async {
    const theme = ShellCursorThemes.yangyangXuanling;

    for (final path in theme.assetPaths) {
      final data = await rootBundle.load(path);
      expect(data.lengthInBytes, greaterThan(0), reason: path);
    }
  });

  test('native and Flutter cursor aliases reach every animated role', () {
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
      ShellCursorKind.handwriting: <String>[
        'handwriting',
        'pencil',
        'nwpen',
      ],
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

  testWidgets('resize artwork advances through its animation frames',
      (tester) async {
    final shapes = StreamController<String>.broadcast(sync: true);
    final positions = StreamController<Offset>.broadcast(sync: true);
    addTearDown(shapes.close);
    addTearDown(positions.close);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ShellCursorHost(
          theme: ShellCursorThemes.yangyangXuanling,
          platformCursorShapes: shapes.stream,
          platformCursorPositions: positions.stream,
          child: const SizedBox.expand(),
        ),
      ),
    );
    positions.add(const Offset(100, 100));
    shapes.add('nw-resize');
    await tester.pump();

    AssetImage cursorImage() {
      return tester.widget<Image>(find.byType(Image)).image as AssetImage;
    }

    expect(
      cursorImage().assetName,
      endsWith('/diagonal_nwse/00.png'),
    );

    await tester.pump(const Duration(microseconds: 83334));
    expect(
      cursorImage().assetName,
      endsWith('/diagonal_nwse/01.png'),
    );

    shapes.add('wait');
    await tester.pump();
    expect(cursorImage().assetName, endsWith('/busy/00.png'));
  });

  testWidgets('drag icon follows native cursor positions and clears on drop',
      (tester) async {
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

DenialDragIcon _dragIcon() {
  return const DenialDragIcon(
    sequence: 1,
    surfaceId: 0x200000004,
    offset: Offset(-12.5, 8.25),
    size: Size(160, 120),
    layer: HyprSurfaceLayer(
      surfaceId: 0x200000004,
      parentSurfaceId: 0,
      popupRootSurfaceId: 0,
      role: HyprSurfaceRole.root,
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
