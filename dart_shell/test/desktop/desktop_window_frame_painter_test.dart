import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:denial_dart_shell/src/desktop/desktop_window_frame_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('frame ring is opaque while the client interior stays clear', () async {
    const logicalSize = ui.Size(48, 32);
    const scale = 4.0;
    const imageWidth = 192;
    const imageHeight = 128;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(scale);

    const DesktopWindowFramePainter().paint(canvas, logicalSize);
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
      _alphaAt(
        data,
        imageWidth,
        x: imageWidth ~/ 2,
        y: imageHeight ~/ 2,
      ),
      0,
    );
  });

  testWidgets('only the static frame picture is forced into raster cache',
      (tester) async {
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
    expect(
      find.ancestor(
        of: find.byWidget(framePaint),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
  });

  test(
      'a retained frame painter repaints only when its window identity changes',
      () {
    const original = DesktopWindowFramePainter(windowId: 7);

    expect(
      const DesktopWindowFramePainter(windowId: 7).shouldRepaint(original),
      isFalse,
    );
    expect(
      const DesktopWindowFramePainter(windowId: 8).shouldRepaint(original),
      isTrue,
    );
  });
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
