import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color, HSVColor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_accent.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';

void main() {
  test('dominant vibrant color follows the strongest saturated hue', () {
    // Two thirds saturated blue, one third saturated red: blue must win, and
    // the result is represented as a canonical, non-rendered accent seed.
    final pixels = _rgbaPixels(<Color>[
      for (var i = 0; i < 200; i += 1) const Color(0xff1040e0),
      for (var i = 0; i < 100; i += 1) const Color(0xffd02020),
    ]);

    final color = dominantVibrantColor(pixels);

    expect(color, isNotNull);
    final hsv = HSVColor.fromColor(color!);
    expect(hsv.hue, closeTo(225, 20));
    expect(hsv.value, closeTo(0.65, 0.01));
    expect(hsv.saturation, inInclusiveRange(0.35, 0.75));
  });

  test('monochrome images produce no accent', () {
    final gray = _rgbaPixels(<Color>[
      for (var i = 0; i < 300; i += 1) const Color(0xff5a5a5a),
    ]);
    final black = _rgbaPixels(<Color>[
      for (var i = 0; i < 300; i += 1) const Color(0xff000000),
    ]);

    expect(dominantVibrantColor(gray), isNull);
    expect(dominantVibrantColor(black), isNull);
    expect(dominantVibrantColor(ByteData(0)), isNull);
  });

  test('a handful of stray colored pixels cannot theme a gray image', () {
    final pixels = _rgbaPixels(<Color>[
      for (var i = 0; i < 5000; i += 1) const Color(0xff404040),
      for (var i = 0; i < 4; i += 1) const Color(0xff00ff00),
    ]);

    expect(dominantVibrantColor(pixels), isNull);
  });

  test(
    'controller publishes a resolved fallback for an unreadable resource',
    () async {
      final container = ProviderContainer.test(
        overrides: [
          wallpaperAccentExtractorProvider.overrideWithValue(
            (resource) async => switch (resource.path) {
              'vivid' => const Color(0xff3366ff),
              _ => throw StateError('unreadable'),
            },
          ),
          wallpaperControllerProvider.overrideWithBuild(
            (ref, controller) => WallpaperExperienceState.initial(),
          ),
          displayLayoutProvider.overrideWithBuild((ref, controller) => null),
        ],
      );
      final controller = container.read(wallpaperAccentProvider.notifier);

      await controller.load(const WallpaperResource.file('vivid'));
      expect(
        container.read(wallpaperAccentProvider).color,
        const Color(0xff3366ff),
      );

      // An unreadable wallpaper falls back to the brand accent rather than
      // failing silently with a stale wallpaper-specific color.
      await controller.load(const WallpaperResource.file('broken'));
      expect(
        container.read(wallpaperAccentProvider),
        WallpaperAccent.resolvedFallback,
      );

      // Re-selecting the earlier wallpaper is served from the cache.
      await controller.load(const WallpaperResource.file('vivid'));
      expect(
        container.read(wallpaperAccentProvider).color,
        const Color(0xff3366ff),
      );
    },
  );

  test('effective accent switches between wallpaper and custom color', () {
    final container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
        wallpaperAccentProvider.overrideWithBuild(
          (ref, controller) => const WallpaperAccent(Color(0xff3366ff)),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(shellAccentProvider).color, const Color(0xff3366ff));
    final controller = container.read(shellSettingsProvider.notifier);
    controller
      ..setCustomAccentColor(const Color(0xffff7043))
      ..setAccentSource(ShellAccentSource.custom);

    expect(container.read(shellAccentProvider).color, const Color(0xffff7043));
  });
}

class _MemorySettingsStore implements SettingsStore {
  @override
  Future<ShellSettings?> read() async => null;

  @override
  Future<void> write(ShellSettings settings) async {}
}

ByteData _rgbaPixels(List<Color> colors) {
  final data = ByteData(colors.length * 4);
  for (var i = 0; i < colors.length; i += 1) {
    final color = colors[i];
    data.setUint8(i * 4, (color.r * 255).round());
    data.setUint8(i * 4 + 1, (color.g * 255).round());
    data.setUint8(i * 4 + 2, (color.b * 255).round());
    data.setUint8(i * 4 + 3, 255);
  }
  return data;
}
