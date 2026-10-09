import 'package:denial_desktop/src/wallpaper/widgets/wallpaper_gallery.dart';
import 'package:denial_desktop/src/wallpaper/widgets/wallpaper_layout_switch.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WallpaperGalleryLayout.resolve', () {
    test('fills a landscape 1080p selector with landscape cells', () {
      // The 1920×1080 selector's tile area is 642 logical pixels tall.
      final layout = WallpaperGalleryLayout.resolve(
        viewport: const Size(1920, 642),
        targetAspectRatio: 1920 / 1080,
      );

      expect(layout.columns, 6);
      expect(layout.horizontalInset, 120);
      expect(layout.tileAspectRatio, closeTo(16 / 9, 1e-9));
      expect(layout.tileWidth, closeTo((1680 - 5 * 14) / 6, 1e-9));
      expect(layout.tileHeight, closeTo(layout.tileWidth * 9 / 16, 1e-9));
      expect(
        layout.columns * layout.tileWidth +
            (layout.columns - 1) * WallpaperGalleryLayout.spacing +
            2 * layout.horizontalInset,
        closeTo(1920, 1e-9),
      );
    });

    test('gives a portrait display portrait cells', () {
      final layout = WallpaperGalleryLayout.resolve(
        viewport: const Size(1080, 1228.8),
        targetAspectRatio: 1080 / 1920,
      );

      expect(layout.columns, 6);
      expect(layout.horizontalInset, 54);
      expect(layout.tileAspectRatio, closeTo(9 / 16, 1e-9));
      expect(layout.tileWidth, closeTo((972 - 5 * 14) / 6, 1e-9));
      expect(layout.tileHeight, greaterThan(layout.tileWidth));
    });

    test('keeps the minimum cell area independent of orientation', () {
      expect(
        WallpaperGalleryLayout.minimumTileWidth(16 / 9),
        closeTo(256, 1e-9),
      );
      expect(
        WallpaperGalleryLayout.minimumTileWidth(9 / 16),
        closeTo(144, 1e-9),
      );
    });

    test('adds columns until a whole row fits a short viewport', () {
      final layout = WallpaperGalleryLayout.resolve(
        viewport: const Size(1000, 150),
        targetAspectRatio: 16 / 9,
      );

      expect(layout.columns, 4);
      expect(layout.tileWidth, closeTo((900 - 3 * 14) / 4, 1e-9));
      expect(
        layout.tileHeight,
        lessThanOrEqualTo(
          150 * WallpaperGalleryLayout.maximumTileHeightFraction,
        ),
      );
    });

    test('drops the side inset when only one narrow column fits', () {
      final layout = WallpaperGalleryLayout.resolve(
        viewport: const Size(200, 400),
        targetAspectRatio: 16 / 9,
      );

      expect(layout.columns, 1);
      expect(layout.horizontalInset, 0);
      expect(layout.tileWidth, 200);
    });

    test('caps the column count on very wide viewports', () {
      final layout = WallpaperGalleryLayout.resolve(
        viewport: const Size(7680, 2764.8),
        targetAspectRatio: 16 / 9,
      );

      expect(layout.columns, WallpaperGalleryLayout.maximumColumns);
      expect(
        layout.columns * layout.tileWidth +
            (layout.columns - 1) * WallpaperGalleryLayout.spacing,
        closeTo(WallpaperGalleryLayout.maximumContentWidth, 1e-9),
      );
    });

    test('degenerate viewports produce one finite, empty column', () {
      for (final viewport in const <Size>[
        Size.zero,
        Size(-20, -20),
        Size(double.infinity, double.infinity),
        Size(double.nan, double.nan),
      ]) {
        final layout = WallpaperGalleryLayout.resolve(
          viewport: viewport,
          targetAspectRatio: 16 / 9,
        );
        expect(layout.columns, 1, reason: '$viewport');
        expect(layout.tileWidth, 0, reason: '$viewport');
        expect(layout.tileHeight, 0, reason: '$viewport');
        expect(layout.horizontalInset, 0, reason: '$viewport');
      }
    });
  });

  group('WallpaperGalleryLayout.sanitizeAspectRatio', () {
    test('falls back to 16:9 when the target size is unknown', () {
      for (final ratio in const <double>[
        0,
        -1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          WallpaperGalleryLayout.sanitizeAspectRatio(ratio),
          WallpaperGalleryLayout.defaultAspectRatio,
          reason: '$ratio',
        );
      }
    });

    test('clamps spanned and extreme targets', () {
      expect(WallpaperGalleryLayout.sanitizeAspectRatio(32 / 9), 2.4);
      expect(WallpaperGalleryLayout.sanitizeAspectRatio(0.2), 0.5);
      expect(WallpaperGalleryLayout.sanitizeAspectRatio(4 / 3), 4 / 3);
    });
  });

  group('WallpaperGalleryLayout.decodeSize', () {
    test('rounds physical tile size up to the decode step', () {
      final layout = WallpaperGalleryLayout.resolve(
        viewport: const Size(1920, 642),
        targetAspectRatio: 16 / 9,
      );

      expect(layout.decodeSize(1), (width: 320, height: 192));
      expect(layout.decodeSize(2), (width: 576, height: 320));
    });

    test('nearby tile sizes share one decoded cache entry', () {
      const smaller = WallpaperGalleryLayout(
        columns: 6,
        tileAspectRatio: 16 / 9,
        tileWidth: 268,
        horizontalInset: 0,
      );
      const larger = WallpaperGalleryLayout(
        columns: 6,
        tileAspectRatio: 16 / 9,
        tileWidth: 270,
        horizontalInset: 0,
      );

      expect(smaller.decodeSize(1), larger.decodeSize(1));
    });

    test('never exceeds the decode bound on dense large displays', () {
      const layout = WallpaperGalleryLayout(
        columns: 1,
        tileAspectRatio: 16 / 9,
        tileWidth: 1600,
        horizontalInset: 0,
      );

      expect(layout.decodeSize(2), (width: 1024, height: 1024));
      expect(layout.decodeSize(1), (width: 1024, height: 960));
    });

    test('treats an invalid device pixel ratio as 1', () {
      const layout = WallpaperGalleryLayout(
        columns: 1,
        tileAspectRatio: 2,
        tileWidth: 200,
        horizontalInset: 0,
      );

      for (final ratio in const <double>[0, -2, double.nan, double.infinity]) {
        expect(layout.decodeSize(ratio), (
          width: 256,
          height: 128,
        ), reason: '$ratio');
      }
    });

    test('empty tiles still request the minimum decode step', () {
      const layout = WallpaperGalleryLayout(
        columns: 1,
        tileAspectRatio: 16 / 9,
        tileWidth: 0,
        horizontalInset: 0,
      );

      expect(layout.decodeSize(2), (width: 64, height: 64));
    });
  });

  group('WallpaperGalleryLayout scrolling', () {
    const layout = WallpaperGalleryLayout(
      columns: 4,
      tileAspectRatio: 2,
      tileWidth: 200,
      horizontalInset: 0,
    );

    test('counts partial rows', () {
      expect(layout.rowCount(0), 0);
      expect(layout.rowCount(1), 1);
      expect(layout.rowCount(4), 1);
      expect(layout.rowCount(5), 2);
      expect(layout.contentHeight(0), 0);
      expect(layout.contentHeight(40), 10 * 100 + 9 * 14);
    });

    test('centers the focused row within the scroll extent', () {
      double offset(int index, {double viewportHeight = 300}) =>
          layout.scrollOffsetFor(
            index,
            itemCount: 40,
            viewportHeight: viewportHeight,
          );

      expect(offset(0), 0);
      expect(offset(13), 3 * 114 - 100);
      expect(offset(39), 1126 - 300);
      expect(offset(999), 1126 - 300);
      expect(offset(-5), 0);
      expect(offset(13, viewportHeight: 2000), 0);
      expect(layout.scrollOffsetFor(3, itemCount: 0, viewportHeight: 300), 0);
    });
  });

  group('wallpaperSelectorLayoutProvider', () {
    test('defaults to the narrow strips', () {
      final container = ProviderContainer.test();

      expect(
        container.read(wallpaperSelectorLayoutProvider),
        WallpaperSelectorLayout.strips,
      );
    });

    test('keeps the chosen layout for the container lifetime', () {
      final container = ProviderContainer.test();
      final notifications = <WallpaperSelectorLayout>[];
      container.listen(
        wallpaperSelectorLayoutProvider,
        (_, next) => notifications.add(next),
      );
      final choice = container.read(wallpaperSelectorLayoutProvider.notifier);

      choice.select(WallpaperSelectorLayout.gallery);
      choice.select(WallpaperSelectorLayout.gallery);

      expect(
        container.read(wallpaperSelectorLayoutProvider),
        WallpaperSelectorLayout.gallery,
      );
      expect(notifications, <WallpaperSelectorLayout>[
        WallpaperSelectorLayout.gallery,
      ]);

      choice.select(WallpaperSelectorLayout.strips);
      expect(
        container.read(wallpaperSelectorLayoutProvider),
        WallpaperSelectorLayout.strips,
      );
    });
  });
}
