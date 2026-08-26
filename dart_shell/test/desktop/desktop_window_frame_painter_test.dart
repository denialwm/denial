import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:denial_dart_shell/src/desktop/desktop_window_frame_painter.dart';
import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('frame ring is opaque while the client interior stays clear', () async {
    const logicalSize = ui.Size(48, 32);
    const scale = 4.0;
    const imageWidth = 192;
    const imageHeight = 128;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(scale);

    DesktopWindowFramePainter(
      shadowColor: ShellColorScheme.dark.shadow,
      frameColor: ShellColorScheme.dark.windowFrameSurface,
    ).paint(canvas, logicalSize);
    final image = await recorder.endRecording().toImage(
      imageWidth,
      imageHeight,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();

    expect(data, isNotNull);
    expect(_alphaAt(data!, imageWidth, x: 2, y: imageHeight ~/ 2), 255);
    expect(_alphaAt(data, imageWidth, x: 8, y: imageHeight ~/ 2), 0);
    expect(
      _alphaAt(data, imageWidth, x: imageWidth ~/ 2, y: imageHeight ~/ 2),
      0,
    );
  });

  testWidgets('only the static frame picture is forced into raster cache', (
    tester,
  ) async {
    const borderPainter = _TestBorderPainter();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 180,
          child: DesktopWindowFrameLayers(
            windowId: 42,
            borderPainter: borderPainter,
            child: ColoredBox(color: Color(0xff123456)),
          ),
        ),
      ),
    );

    final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
    final framePaint = paints.singleWhere(
      (paint) => paint.painter is DesktopWindowFramePainter,
    );
    final borderPaint = paints.singleWhere(
      (paint) => identical(paint.painter, borderPainter),
    );

    expect(framePaint.isComplex, isTrue);
    expect(framePaint.willChange, isFalse);
    expect(borderPaint.isComplex, isFalse);
    expect(borderPaint.willChange, isFalse);
    final frameRenderObject = tester.renderObject(find.byWidget(framePaint));
    final shadowBoundary = frameRenderObject.parent!.parent! as RenderBox;
    expect(
      shadowBoundary.paintBounds,
      (Offset.zero & shadowBoundary.size).inflate(64),
      reason: 'the retained layer must include every pixel the shadow paints',
    );
    expect(
      find.ancestor(
        of: find.byWidget(framePaint),
        matching: find.byWidgetPredicate((widget) => widget is RepaintBoundary),
      ),
      findsOneWidget,
    );
  });

  testWidgets('every retained ancestor preserves the frame shadow outset', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 180,
          child: DesktopWindowRepaintBoundary(
            outset: DesktopWindowFramePainter.shadowOutset,
            child: DesktopWindowFrameLayers(
              windowId: 42,
              borderPainter: _TestBorderPainter(),
              child: ColoredBox(color: Color(0xff123456)),
            ),
          ),
        ),
      ),
    );

    final boundaries = tester
        .renderObjectList<RenderBox>(
          find.byWidgetPredicate(
            (widget) => widget is DesktopWindowRepaintBoundary,
          ),
        )
        .toList();
    expect(boundaries, hasLength(2));
    for (final boundary in boundaries) {
      expect(
        boundary.paintBounds,
        (Offset.zero & boundary.size).inflate(
          DesktopWindowFramePainter.shadowOutset,
        ),
        reason: 'an ancestor boundary must not crop descendant shadow damage',
      );
    }
  });

  test(
    'a retained frame painter repaints only when its window identity changes',
    () {
      final original = DesktopWindowFramePainter(
        windowId: 7,
        shadowColor: ShellColorScheme.dark.shadow,
        frameColor: ShellColorScheme.dark.windowFrameSurface,
      );

      expect(
        DesktopWindowFramePainter(
          windowId: 7,
          shadowColor: ShellColorScheme.dark.shadow,
          frameColor: ShellColorScheme.dark.windowFrameSurface,
        ).shouldRepaint(original),
        isFalse,
      );
      expect(
        DesktopWindowFramePainter(
          windowId: 8,
          shadowColor: ShellColorScheme.dark.shadow,
          frameColor: ShellColorScheme.dark.windowFrameSurface,
        ).shouldRepaint(original),
        isTrue,
      );
    },
  );
}

int _alphaAt(ByteData data, int width, {required int x, required int y}) {
  return data.getUint8(((y * width) + x) * 4 + 3);
}

class _TestBorderPainter extends CustomPainter {
  const _TestBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant _TestBorderPainter oldDelegate) => false;
}
