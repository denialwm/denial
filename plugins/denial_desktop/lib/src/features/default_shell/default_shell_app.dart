import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/launcher.dart';
import 'package:denial_flutter_sdk/pets.dart';

import '../../core/denial_shell.dart';

import 'package:denial_flutter_sdk/shell.dart';
import 'package:denial_flutter_sdk/environment.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/desktop_shell.dart';
import '../../desktop/desktop_workspace.dart';
import '../../diagnostics/glass_benchmark.dart';
import '../../state/desktop_window_switcher.dart';

import 'package:denial_flutter_sdk/wallpaper.dart';

import '../../wallpaper/widgets/mobile_wallpaper_selector_layer.dart';
import '../../widgets/connectivity/bluetooth_detail_surface.dart';
import '../../widgets/notification_banner.dart';
import '../../widgets/system_level_hud.dart';
import '../mobile/mobile_application_scene.dart';
import '../mobile/mobile_frame_timing_overlay.dart';
import 'panel_composition.dart';

/// The reference plugin's desktop/mobile assembly. Alternative ShellApplication
/// providers compose SDK primitives directly; this is not a platform API.
class DenialShellApp extends StatelessWidget {
  const DenialShellApp({
    this.desktopSurfaces = const [],
    this.desktopWorkArea,
    this.desktopLauncher,
    this.actions = const [],
    this.desktopPetHolds,
    this.desktopPetShadows,
    super.key,
  });

  final List<ShellSurface> desktopSurfaces;
  final ShellWorkArea? desktopWorkArea;
  final ShellLauncher? desktopLauncher;
  final List<ShellAction> actions;
  final ShellPetHolds? desktopPetHolds;
  final ShellPetShadows? desktopPetShadows;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        desktopSurfacesProvider.overrideWithValue(desktopSurfaces),
        desktopLauncherProvider.overrideWithValue(desktopLauncher),
        desktopActionsProvider.overrideWithValue(actions),
        desktopPetHoldsProvider.overrideWithValue(desktopPetHolds),
        desktopPetShadowsProvider.overrideWithValue(desktopPetShadows),
      ],
      child: DenialShell(
        desktopWorkArea: desktopWorkArea,
        mobile: const DenialShellScene(
          content: MobileApplicationScene(),
          chrome: MobileShellChrome(),
          overlays: <Widget>[
            SystemLevelHudLayer(),
            NotificationBannerLayer(mobile: true),
            MobileWallpaperSelectorLayer(),
            MobileFrameTimingOverlay(),
            GlassBenchmarkLayer(),
          ],
        ),
        desktop: const DenialShellScene(
          content: DesktopShell(),
          overlays: desktopWindowsOnly
              ? <Widget>[]
              : <Widget>[SystemLevelHudLayer(), NotificationBannerLayer()],
        ),
        pairingSurfaceBuilder: _buildPairingSurface,
        onLocked: _closeFeatureSurfaces,
      ),
    );
  }
}

Widget _buildPairingSurface(BuildContext context, VoidCallback close) {
  return BluetoothDetailSurface(onClose: close);
}

void _closeFeatureSurfaces(WidgetRef ref) {
  ref.read(desktopWindowSwitcherProvider.notifier).cancel();
  ref.read(desktopWorkspaceProvider.notifier).closeOverview();
  ref.read(wallpaperControllerProvider.notifier).closeSelector();
}
