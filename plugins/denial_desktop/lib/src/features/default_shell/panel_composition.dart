import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/pets.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/window_frames/built_in_window_frame.dart';

/// Statically supplied by the application; no runtime discovery or selection.
final desktopSurfacesProvider = Provider<List<ShellSurface>>((ref) => const []);

/// Optional launcher selected by the compiled application.
final desktopLauncherProvider = Provider<ShellLauncher?>((ref) => null);

final desktopActionsProvider = Provider<List<ShellAction>>((ref) => const []);

/// Optional pet holds selected by the compiled application. Without one,
/// desktop pets are only ever let go free.
final desktopPetHoldsProvider = Provider<ShellPetHolds?>((ref) => null);

/// Optional pet shadows selected by the compiled application. Without one,
/// held pets cast nothing on their windows.
final desktopPetShadowsProvider = Provider<ShellPetShadows?>((ref) => null);

/// Optional window frame plugin selected by the compiled application.
final pluginWindowFrameProvider = Provider<ShellWindowFrame?>((ref) => null);

/// The frame the desktop draws around decorated windows now: a plugin's when
/// the application has one, else Denial's own while the stacking layout has
/// `layout.windowFrames` on. Null draws the desktop's plain border.
final desktopWindowFrameProvider = Provider<ShellWindowFrame?>((ref) {
  final plugin = ref.watch(pluginWindowFrameProvider);
  if (plugin != null) {
    return plugin;
  }
  final builtIn = ref.watch(
    shellSettingsProvider.select(
      (settings) =>
          settings.layout.windowFrames &&
          settings.layout.windowLayout == DesktopWindowLayout.stacking,
    ),
  );
  return builtIn ? const BuiltInWindowFrame() : null;
});
