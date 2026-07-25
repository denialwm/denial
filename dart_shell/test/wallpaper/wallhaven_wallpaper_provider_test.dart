import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/wallpaper/providers/wallhaven_wallpaper_provider.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_image.dart';

void main() {
  test('orders valid Wallhaven results for the target display aspect ratio',
      () {
    final results = WallhavenWallpaperProvider.parseSearchResponse(
      <String, dynamic>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'landscape',
            'path': 'https://w.wallhaven.cc/full/aa/wallhaven-landscape.jpg',
            'short_url': 'https://wallhaven.cc/w/landscape',
            'dimension_x': 2560,
            'dimension_y': 1440,
            'thumbs': <String, Object?>{
              'large': 'https://th.wallhaven.cc/lg/aa/landscape.jpg',
            },
          },
          <String, Object?>{
            'id': 'portrait',
            'path': 'https://w.wallhaven.cc/full/bb/wallhaven-portrait.jpg',
            'short_url': 'https://wallhaven.cc/w/portrait',
            'dimension_x': 1200,
            'dimension_y': 2400,
            'thumbs': <String, Object?>{
              'large': 'https://th.wallhaven.cc/lg/bb/portrait.jpg',
            },
          },
        ],
      },
      providerId: 'wallhaven',
      targetAspectRatio: 0.5,
    );

    expect(results.map((item) => item.id), <String>['portrait', 'landscape']);
    expect(results.first.downloadUri?.scheme, 'https');
    expect(results.first.previewUri, results.first.downloadUri);
    expect(
      results.first.previewUri.host,
      'w.wallhaven.cc',
      reason: 'carousel previews use the full-resolution image, not thumbs',
    );
    expect(results.first.width, 1200);
    expect(results.first.height, 2400);
    final preview = wallpaperCandidateImageProvider(
      results.first,
      cacheHeight: 900,
    );
    expect(preview, isA<ResizeImage>());
    expect((preview! as ResizeImage).height, 900);
  });

  test('rejects insecure and non-Wallhaven image URLs', () {
    final results = WallhavenWallpaperProvider.parseSearchResponse(
      <String, dynamic>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'http',
            'path': 'http://w.wallhaven.cc/full/aa/insecure.jpg',
            'dimension_x': 1920,
            'dimension_y': 1080,
          },
          <String, Object?>{
            'id': 'foreign',
            'path': 'https://example.com/wallpaper.jpg',
            'dimension_x': 1920,
            'dimension_y': 1080,
          },
        ],
      },
      providerId: 'wallhaven',
      targetAspectRatio: 16 / 9,
    );

    expect(results, isEmpty);
  });
}
