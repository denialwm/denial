import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

import 'desktop_pixel_alignment.dart';

class DesktopLayerShellSurface extends StatelessWidget {
  const DesktopLayerShellSurface({
    required this.surface,
    required this.displayLayout,
    this.rect,
    this.material = true,
    super.key,
  });

  final DenialWindow surface;
  final DisplayLayout? displayLayout;

  /// Where the shell places the surface instead of its own geometry, as a
  /// phone places system overlays above its keyboard.
  final Rect? rect;

  /// False when the caller draws the glass under the surface itself, as a
  /// phone does for its own overlays.
  final bool material;

  static final _overlayMaterialThemes = Expando<ShellThemeData>();

  /// Denial's own overlays, such as the authentication prompt, draw their
  /// translucent card inside a transparent canvas. Third-party overlays such
  /// as region selectors and color pickers keep an unfiltered desktop.
  static bool _receivesMaterial(DenialWindow surface) =>
      surface.contentKind == DenialWindowContentKind.layerShellOverlay &&
      surface.appId.startsWith('dev.denial.') &&
      surface.popupSurfaceLayers.isEmpty;

  /// Frosted material without bevel optics: those would trace the canvas
  /// rectangle instead of the card. The client draws its own rim lighting.
  static ImageFilterConfig? _overlayBackdrop(ShellThemeData theme) {
    final available =
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0) &&
        theme.backdropBlurOpacityThreshold < 1;
    if (!available) return null;
    final quiet = _overlayMaterialThemes[theme] ??= theme.copyWith(
      glass: theme.glass.copyWith(
        edgeStrength: 0,
        lightIntensity: 0,
        refraction: 0,
        dispersion: 0,
      ),
    );
    return quiet.backdropFilterConfigAt(1, useWindowAlphaThreshold: true);
  }

  @override
  Widget build(BuildContext context) {
    final geometry = surface.geometry;
    if (geometry == null || surface.surfaceLayers.isEmpty) {
      return const SizedBox.shrink();
    }
    final outputPixelGrid = desktopOutputPixelGridForMonitor(
      displayLayout,
      surface.monitorId,
    );
    final pixelGridOrigin = outputPixelGrid?.logicalRect.topLeft ?? Offset.zero;
    final texture = _receivesMaterial(surface)
        ? singleWindowPlaneTexture(surface)
        : null;
    return Positioned.fromRect(
      rect: rect ?? geometry,
      // Flutter paints the client texture, while DesktopInputLayoutPublisher
      // transfers pointer and touch ownership to the native Wayland route.
      // Keeping this widget transparent avoids duplicating that lifecycle in
      // Flutter's gesture arena.
      child: IgnorePointer(
        child: RepaintBoundary(
          child: texture == null
              ? WindowSurfaceTree(
                  window: surface,
                  includePopups: true,
                  presentationScale: outputPixelGrid?.scale,
                  pixelGridOrigin: pixelGridOrigin,
                )
              // Like a toplevel, the window primitive composites the client
              // over its material per pixel: only the card's coverage above
              // the user's opacity threshold is frosted, never its shadow.
              : WindowPlane.texture(
                  texture: texture,
                  backdrop: material
                      ? _overlayBackdrop(ShellTheme.of(context))
                      : null,
                  presentationScale:
                      outputPixelGrid?.scale ??
                      MediaQuery.devicePixelRatioOf(context),
                  pixelGridOrigin: pixelGridOrigin,
                ),
        ),
      ),
    );
  }
}

/// Owns overview input while keeping wallpaper-plane controls interactive.
///
/// The full-scene region transfers native pointer ownership to Flutter. The
/// dismissal barrier then handles otherwise-unclaimed taps, while controls
/// painted after it (such as the workspace indicator and system tray) win
/// Flutter hit testing inside their own bounds.
class DesktopOverviewInputLayer extends StatelessWidget {
  const DesktopOverviewInputLayer({
    required this.active,
    required this.onBarrierTap,
    required this.foregroundControls,
    this.decoration,
    super.key,
  });

  final bool active;
  final ValueChanged<Offset> onBarrierTap;
  final List<Widget> foregroundControls;

  /// Overview chrome above the dismissal barrier, such as workspace cards.
  /// Its own hit regions take taps; everything else reaches the barrier.
  final Widget? decoration;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: ShellInputRegion(
            debugLabel: 'Desktop overview',
            active: active,
            pointerPolicy: ShellPointerPolicy.fullScene,
            keyboardPolicy: ShellKeyboardPolicy.capture,
            compositorPolicy: ShellCompositorPolicy.exclusive,
            child: const IgnorePointer(child: SizedBox.expand()),
          ),
        ),
        Positioned.fill(
          child: _DesktopOverviewBarrier(active: active, onTap: onBarrierTap),
        ),
        if (decoration case final decoration?)
          Positioned.fill(child: decoration),
        ...foregroundControls,
      ],
    );
  }
}

class _DesktopOverviewBarrier extends StatelessWidget {
  const _DesktopOverviewBarrier({required this.active, required this.onTap});

  final bool active;
  final ValueChanged<Offset> onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => onTap(details.localPosition),
      ),
    );
  }
}
