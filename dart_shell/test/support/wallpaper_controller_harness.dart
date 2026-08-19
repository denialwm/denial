import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper_provider.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class WallpaperControllerTestHarness {
  WallpaperControllerTestHarness({
    required List<WallpaperProvider> sources,
    required WallpaperStore store,
    DisplayLayout? displayLayout,
  }) : container = ProviderContainer.test(
         overrides: [
           wallpaperSourcesProvider.overrideWithValue(sources),
           wallpaperStoreProvider.overrideWithValue(store),
           displayLayoutProvider.overrideWithBuild(
             (ref, controller) => displayLayout,
           ),
           shellControllerProvider.overrideWith(
             _WallpaperHarnessShellController.new,
           ),
         ],
       ) {
    controller = container.read(wallpaperControllerProvider.notifier);
  }

  final ProviderContainer container;
  late final WallpaperController controller;

  WallpaperExperienceState get state =>
      container.read(wallpaperControllerProvider);
}

class _WallpaperHarnessShellController extends ShellController {
  @override
  ShellState build() => ShellState.initial(locked: false);
}
