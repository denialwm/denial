import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';
import 'package:denial_desktop/src/state/reference_shell_profile.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/desktop_scene_layers.dart';
import '../../state/phone_desk.dart';

/// The phone's wallpaper client, such as Phonewave's `video-wallpaper`: a
/// background layer surface with content. None on the desktop presentation.
///
/// It covers the shell's own wallpaper on the home and lock screens. That
/// one stays beneath it, frosted once for the glass of windows and panels:
/// a moving picture is never captured.
final mobileWallpaperClientProvider = Provider<DenialWindow?>((ref) {
  if (ref.watch(referenceShellPresentationProvider) !=
      ReferenceShellProfile.mobile) {
    return null;
  }
  return ref.watch(
    referenceShellProvider.select((state) {
      for (final surface in state.layerSurfaces.reversed) {
        if (surface.contentKind ==
                DenialWindowContentKind.layerShellBackground &&
            !surface.isHeld &&
            !surface.minimized &&
            surface.geometry != null &&
            surface.surfaceLayers.isNotEmpty) {
          return surface;
        }
      }
      return null;
    }),
  );
});

/// Draws [mobileWallpaperClientProvider]'s surface over the whole box.
///
/// Denial asks the client for frames only while some output shows it, so
/// wherever this is offstage or covered the client decodes nothing.
class MobileWallpaperClient extends ConsumerWidget {
  const MobileWallpaperClient({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surface = ref.watch(mobileWallpaperClientProvider);
    if (surface == null) {
      return const SizedBox.shrink();
    }
    final displayLayout = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context)),
    );
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          DesktopLayerShellSurface(
            key: ValueKey<String>('wallpaper-client-${surface.surfaceId}'),
            surface: surface,
            displayLayout: displayLayout,
            rect: Offset.zero & constraints.biggest,
          ),
        ],
      ),
    );
  }
}
