import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('obsolete wallpaper cache entries are released after swaps', (
    tester,
  ) async {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache
      ..clear()
      ..clearLiveImages();
    addTearDown(() {
      imageCache
        ..clear()
        ..clearLiveImages();
    });

    for (var swap = 0; swap < 20; swap++) {
      final key = 'wallpaper-${swap.isEven ? 0 : 1}';
      imageCache.putIfAbsent(key, _PendingImageStreamCompleter.new);
      final lease = WallpaperImageCacheLease(
        _KeyedImageProvider(key),
        ImageConfiguration.empty,
      );

      expect(imageCache.statusForKey(key).pending, isTrue);
      lease.release();
      await tester.idle();
      expect(
        imageCache.statusForKey(key).untracked,
        isTrue,
        reason: 'wallpaper swap ${swap + 1}',
      );
    }
  });

  testWidgets('a shared wallpaper stays cached until its last scene leaves', (
    tester,
  ) async {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache
      ..clear()
      ..clearLiveImages();
    addTearDown(() {
      imageCache
        ..clear()
        ..clearLiveImages();
    });

    const key = 'shared-wallpaper';
    const provider = _KeyedImageProvider(key);
    imageCache.putIfAbsent(key, _PendingImageStreamCompleter.new);
    final first = WallpaperImageCacheLease(provider, ImageConfiguration.empty);
    final second = WallpaperImageCacheLease(provider, ImageConfiguration.empty);

    first.release();
    await tester.idle();
    expect(imageCache.statusForKey(key).pending, isTrue);

    second.release();
    await tester.idle();
    expect(imageCache.statusForKey(key).untracked, isTrue);
  });
}

class _PendingImageStreamCompleter extends ImageStreamCompleter {}

class _KeyedImageProvider extends ImageProvider<String> {
  const _KeyedImageProvider(this.key);

  final String key;

  @override
  Future<String> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<String>(key);

  @override
  ImageStreamCompleter loadImage(String key, ImageDecoderCallback decode) {
    throw UnsupportedError('The cache lease test resolves keys only.');
  }

  @override
  bool operator ==(Object other) =>
      other is _KeyedImageProvider && other.key == key;

  @override
  int get hashCode => key.hashCode;
}
