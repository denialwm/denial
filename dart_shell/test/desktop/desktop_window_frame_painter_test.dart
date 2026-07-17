import 'dart:typed_data';
import 'dart:ui' as ui;

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
}

int _alphaAt(ByteData data, int width, {required int x, required int y}) {
  return data.getUint8(((y * width) + x) * 4 + 3);
}
