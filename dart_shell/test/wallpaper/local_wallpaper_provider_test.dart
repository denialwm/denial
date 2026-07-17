import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/wallpaper/providers/local_wallpaper_provider.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';

void main() {
  test('does not repeat the bundled default from the local library', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-local-wallpapers-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/wallhaven-28ylpg.jpg').writeAsBytes(<int>[1]);
    await File('${directory.path}/another-wallpaper.png')
        .writeAsBytes(<int>[2]);
    final provider = LocalWallpaperProvider(directory: directory);

    final page = await provider.search(
      const WallpaperQuery(
        text: '',
        page: 1,
        limit: 24,
        targetPixelSize: Size(2560, 1440),
      ),
    );

    expect(page.items.where((item) => item.id == 'default'), hasLength(1));
    expect(
      page.items.where(
        (item) => item.label.toLowerCase() == 'wallhaven-28ylpg',
      ),
      isEmpty,
    );
    expect(page.items.map((item) => item.label), contains('another-wallpaper'));
  });
}
