import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/desktop_scene_layers.dart';
import 'mobile_application_scene.dart' show mobileWallpaperGlassProvider;
import '../../state/phone_desk.dart';

/// Denial's own overlay, such as the authentication prompt, above the
/// phone's shell and apps and below its keyboard, over a dimmed screen.
///
/// It sits where `ReferenceShellMetrics.systemOverlayRect` says, between the
/// status bar and the keyboard, and the input layout hands it the touches
/// there; the dimmed rest belongs to the shell and does nothing.
///
/// On a phone the overlay is its card and nothing more, so the shell gives
/// all of it the glass phone windows have: the wallpaper frosted once.
class MobileSystemOverlayLayer extends ConsumerWidget {
  const MobileSystemOverlayLayer({super.key});

  static const Color _dim = Color(0x73000000);
  static const Duration _fade = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overlay = ref.watch(
      referenceShellProvider.select((state) => state.systemOverlay),
    );
    final keyboard = ref.watch(
      referenceShellProvider.select((state) => state.edgePanelDragProgress),
    );
    final displayLayout = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context)),
    );
    final viewSize = MediaQuery.sizeOf(context);
    final theme = ShellTheme.of(context);
    final glass =
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0);
    final rect = overlay == null
        ? null
        : ReferenceShellMetrics.systemOverlayRect(
            viewSize,
            overlay.geometry!.size,
            keyboard,
          );
    return IgnorePointer(
      child: ValueListenableBuilder<FrostedBackdrop?>(
        valueListenable: ref.watch(mobileWallpaperGlassProvider),
        builder: (context, backdrop, layer) => WindowBackdropCache(
          backdrop: backdrop,
          motion: const AlwaysStoppedAnimation<double>(0),
          child: layer!,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              opacity: overlay == null ? 0 : 1,
              duration: _fade,
              child: const ColoredBox(color: _dim),
            ),
            if (overlay != null && rect != null)
              TweenAnimationBuilder<double>(
                key: ValueKey<String>('system-overlay-${overlay.surfaceId}'),
                tween: Tween(begin: 0, end: 1),
                duration: _fade,
                // The card settles its size in its first frames; it fades in
                // meanwhile.
                builder: (context, shown, layer) =>
                    Opacity(opacity: shown, child: layer),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (glass)
                      Positioned.fromRect(
                        rect: rect,
                        child: Builder(
                          builder: (context) {
                            final cache = WindowBackdropCache.maybeOf(context);
                            if (cache == null) return const SizedBox.shrink();
                            return WindowBackdropSlice(
                              cache: cache,
                              // The prompt rounds its card the same way.
                              borderRadius: BorderRadius.circular(
                                theme.panelRadius.clamp(8.0, 44.0),
                              ),
                              glass: theme.windowGlassShading,
                            );
                          },
                        ),
                      ),
                    DesktopLayerShellSurface(
                      surface: overlay,
                      displayLayout: displayLayout,
                      rect: rect,
                      material: false,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
