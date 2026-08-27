import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/desktop_shell.dart';
import '../../wallpaper/state/wallpaper_controller.dart';
import '../../wallpaper/widgets/mobile_wallpaper_selector_layer.dart';
import '../../widgets/connectivity/bluetooth_detail_surface.dart';
import '../../widgets/notification_banner.dart';
import '../../widgets/system_level_hud.dart';
import '../mobile/mobile_application_scene.dart';
import '../mobile/mobile_frame_timing_overlay.dart';

/// The product shell assembled from Denial's reusable host and stock features.
///
/// Alternate shells can replace this widget and keep [DenialShell] as their
/// root, without importing any of these default feature implementations.
class DenialShellApp extends StatelessWidget {
  const DenialShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const DenialShell(
      mobile: DenialShellScene(
        content: MobileApplicationScene(),
        chrome: MobileShellChrome(),
        overlays: <Widget>[
          SystemLevelHudLayer(),
          NotificationBannerLayer(),
          MobileWallpaperSelectorLayer(),
          MobileFrameTimingOverlay(),
        ],
      ),
      desktop: DenialShellScene(
        content: DesktopShell(),
        overlays: <Widget>[SystemLevelHudLayer(), NotificationBannerLayer()],
      ),
      pairingSurfaceBuilder: _buildPairingSurface,
      onLocked: _closeFeatureSurfaces,
    );
  }
}

Widget _buildPairingSurface(BuildContext context, VoidCallback close) {
  return BluetoothDetailSurface(onClose: close);
}

void _closeFeatureSurfaces(WidgetRef ref) {
  ref.read(wallpaperControllerProvider.notifier).closeSelector();
}
