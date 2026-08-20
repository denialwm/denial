import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late WallpaperResource wallpaper;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('denial-wallpaper-test-');
    wallpaper = WallpaperResource.file(
      await _writePng(temporary, width: 480, height: 240),
    );
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await temporary.delete(recursive: true);
  });

  test('decodes a matching wallpaper at the covered resolution', () async {
    final size = await _decodedSize(
      wallpaperImageProvider(wallpaper, targetPixelSize: const Size(120, 60)),
    );

    expect(size, const Size(120, 60));
  });

  test('preserves enough pixels for BoxFit.cover cropping', () async {
    final size = await _decodedSize(
      wallpaperImageProvider(wallpaper, targetPixelSize: const Size(120, 120)),
    );

    expect(size, const Size(240, 120));
  });

  test('does not upscale a wallpaper smaller than the target', () async {
    final size = await _decodedSize(
      wallpaperImageProvider(wallpaper, targetPixelSize: const Size(960, 480)),
    );

    expect(size, const Size(480, 240));
  });
}

Future<String> _writePng(
  Directory directory, {
  required int width,
  required int height,
}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) {
    throw StateError('Could not encode test wallpaper');
  }
  final file = File('${directory.path}/wallpaper.png');
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file.path;
}

Future<Size> _decodedSize(ImageProvider<Object> provider) {
  final result = Completer<Size>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, synchronousCall) {
      if (!result.isCompleted) {
        result.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      }
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!result.isCompleted) {
        result.completeError(error, stackTrace);
      }
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return result.future;
}
