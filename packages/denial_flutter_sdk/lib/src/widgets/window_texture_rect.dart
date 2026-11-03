import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';
import '../theme/glass_configuration.dart';
import '../theme/shell_theme.dart';

import 'window_backdrop_cache.dart';
import 'window_plane.dart';
import 'window_surface_tree.dart';

/// Fills its parent with a compositor window, covering it like the mobile
/// stage does, through the same [WindowPlane] primitive as desktop windows.
///
/// The primitive draws the client image and its glass as one window surface.
/// A blur widget over a raw texture relies on the engine fusing the two.
/// Scaled or moving windows (recents, launch, focus zoom) defeat that fusion
/// and the fallback floods glass over the scene.
class WindowTextureRect extends StatelessWidget {
  const WindowTextureRect({
    super.key,
    required this.window,
    this.borderRadius = BorderRadius.zero,
    this.applyBackdrop = true,
  });

  final DenialWindow window;
  final BorderRadius borderRadius;
  final bool applyBackdrop;

  @override
  Widget build(BuildContext context) {
    assert(
      !window.isLocalFlutter,
      'Local Flutter windows must be rendered through WindowContentRect.',
    );
    final theme = ShellTheme.of(context);
    final glass =
        applyBackdrop &&
        !window.isOpaque &&
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0);
    final cache = glass ? WindowBackdropCache.maybeOf(context) : null;
    final windowSize = Size(window.width.toDouble(), window.height.toDouble());
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final texture = window.popupSurfaceLayers.isEmpty
        ? singleWindowPlaneTexture(window)
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final parent = constraints.biggest;
        if (windowSize.isEmpty || parent.isEmpty || !parent.isFinite) {
          return const SizedBox.shrink();
        }
        // The window keeps its aspect and covers the parent from the top,
        // like the mobile stage. As on the desktop, the plane is laid out at
        // its on-screen size and maps the buffer itself: its material is
        // resolved in the plane's own units and must not sit under a
        // buffer-to-screen scale.
        final size =
            windowSize *
            math.max(
              parent.width / windowSize.width,
              parent.height / windowSize.height,
            );
        final radius = borderRadius.topLeft.x;
        final backdrop = glass && cache == null
            ? theme.backdropFilterConfigAt(
                1,
                borderRadius: BorderRadius.circular(radius),
                // The mobile stage frosts the whole window, including fully
                // transparent pixels, like the shell's own glass panels.
              )
            : null;
        final Widget plane = texture != null
            ? WindowPlane.texture(
                texture: texture,
                radius: radius,
                backdrop: backdrop,
                filterQuality: FilterQuality.low,
                presentationScale: devicePixelRatio,
              )
            : WindowPlane.child(
                radius: radius,
                backdrop: backdrop,
                child: WindowSurfaceTree(
                  window: window,
                  includePopups: true,
                  filterQuality: FilterQuality.low,
                ),
              );
        Widget covered = OverflowBox(
          alignment: Alignment.topCenter,
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
          child: plane,
        );
        if (cache != null) {
          // A precomputed backdrop replaces the live glass under the plane.
          covered = Stack(
            fit: StackFit.expand,
            children: [
              WindowBackdropSlice(
                cache: cache,
                borderRadius: BorderRadius.circular(radius),
                glass: theme.windowGlassShading,
              ),
              covered,
            ],
          );
        }
        // The plane rounds its own corners. Clip only a window whose aspect
        // differs from the parent's and therefore overflows it.
        if (size.width <= parent.width + 0.5 &&
            size.height <= parent.height + 0.5) {
          return covered;
        }
        return borderRadius == BorderRadius.zero
            ? ClipRect(child: covered)
            : ClipRRect(borderRadius: borderRadius, child: covered);
      },
    );
  }
}
