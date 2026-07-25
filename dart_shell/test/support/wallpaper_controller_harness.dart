import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class WallpaperControllerTestHarness {
  WallpaperControllerTestHarness({
    required List<WallpaperProvider> sources,
    required WallpaperStore store,
  }) : container = ProviderContainer.test(
         overrides: [
           wallpaperSourcesProvider.overrideWithValue(sources),
           wallpaperStoreProvider.overrideWithValue(store),
         ],
       ) {
    controller = container.read(wallpaperControllerProvider.notifier);
  }

  final ProviderContainer container;
  late final WallpaperController controller;

  WallpaperExperienceState get state =>
      container.read(wallpaperControllerProvider);
}
