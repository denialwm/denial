import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_pixel_alignment.dart';
import 'desktop_texture_resize.dart';
import 'desktop_window_frame.dart';
import 'desktop_workspace.dart';
import '../state/phone_desk.dart';

class DesktopPopupSurfaceLayers extends StatelessWidget {
  const DesktopPopupSurfaceLayers({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.offscreenMinimized,
    required this.overviewActive,
    required this.overview,
    required this.switching,
    required this.motionDuration,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
  final bool offscreenMinimized;
  final bool overviewActive;
  final bool overview;
  final bool switching;
  final Duration motionDuration;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final window =
            ref.watch(
              referenceShellProvider.select(
                (state) => state.desk.windowByObjectId(this.window.objectId),
              ),
            ) ??
            this.window;
        final liveGeometry = ref.watch(
          desktopWorkspaceProvider.select((state) {
            final placement = state.placements[this.placement.objectId];
            return placement == null
                ? null
                : (
                    frameSize: placement.frame.size,
                    dragging: placement.dragging,
                  );
          }),
        );
        final selectedPlacement = ref.read(
          desktopWorkspaceProvider.select(
            (state) => state.placements[this.placement.objectId],
          ),
        );
        final followsLivePlacement =
            this.placement.dragging &&
            liveGeometry?.dragging == true &&
            selectedPlacement != null;
        final placement = followsLivePlacement
            ? selectedPlacement
            : this.placement;
        final outputPixelGrid = ref.watch(
          deskDisplayLayoutProvider.select(
            (layout) =>
                desktopOutputPixelGridForMonitor(layout, placement.monitorId),
          ),
        );
        final devicePixelRatio =
            outputPixelGrid?.scale ?? MediaQuery.devicePixelRatioOf(context);
        final pixelGridOrigin =
            outputPixelGrid?.logicalRect.topLeft ?? Offset.zero;
        final liveFrame = followsLivePlacement
            ? desktopLivePlacementVisualFrame(
                visualFrame: this.frame,
                placementFrame: this.placement.frame,
                livePlacementFrame: placement.frame,
              )
            : this.frame;
        final transformed = overview || switching || offscreenMinimized;
        final outputClip = desktopOutputClip(
          activelyDragging: placement.dragging,
          outputRect: outputPixelGrid?.logicalRect,
        );
        final frame = desktopPixelAlignedWindowFrame(
          frame: liveFrame,
          contentInset: placement.frameBorder,
          devicePixelRatio: devicePixelRatio,
          pixelGridOrigin: pixelGridOrigin,
          enabled: !transformed,
          alignSize: true,
        );
        if (window.surfaceLayers.isEmpty) {
          return const SizedBox.shrink();
        }

        final drawsServerFrame = transformed
            ? placement.serverSideDecorated
            : placement.drawsLiveServerFrame;
        final contentRect = drawsServerFrame
            ? frame.deflate(DesktopMetrics.frameBorder)
            : frame;
        final retainedContentRect = drawsServerFrame
            ? placement.frame.deflate(DesktopMetrics.frameBorder)
            : placement.frame;
        final duration = placement.dragging ? Duration.zero : motionDuration;
        final resizing = desktopTextureNeedsResizeSmoothing(
          targetSize: contentRect.size,
          sourceSize: window.contentCoordinateRect.size,
        );
        final filterQuality = transformed || resizing
            ? FilterQuality.medium
            : FilterQuality.none;

        return Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: duration,
              curve: minimized
                  ? Motion.md3EmphasizedAccelerate
                  : Motion.md3EmphasizedDecelerate,
              opacity: desktopWindowPresentationOpacity(
                transparencyMode: ShellTheme.of(context).transparencyMode,
                minimized: minimized,
                desktopWidget: false,
                windowOpacity: 1.0,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final layer in window.popupSurfaceLayers)
                    if (layer.textureId > 0)
                      DesktopAnimatedWindowPosition(
                        key: ValueKey<int>(layer.surfaceId),
                        duration: duration,
                        rect: window.mapSurfaceRect(layer, contentRect),
                        layoutRect: transformed
                            ? window.mapSurfaceRect(layer, retainedContentRect)
                            : null,
                        placementObjectId: placement.objectId,
                        overview: overview,
                        switching: switching,
                        offscreenMinimized: offscreenMinimized,
                        dragging: placement.dragging,
                        resizing: placement.resizing,
                        layoutPreviewing: placement.layoutPreviewing,
                        pixelAlignmentInset: 0.0,
                        pixelGridScale: devicePixelRatio,
                        pixelGridOrigin: pixelGridOrigin,
                        alignSizeToDevicePixels: true,
                        globalClipRect: outputClip,
                        // The window primitive composites the client
                        // over its material per pixel, like a toplevel.
                        child: WindowPlane.texture(
                          texture: WindowPlaneTexture(
                            id: layer.textureId,
                            bufferSize: Size(
                              layer.width.toDouble(),
                              layer.height.toDouble(),
                            ),
                            source: Rect.fromLTWH(
                              layer.textureSourceX,
                              layer.textureSourceY,
                              layer.textureSourceWidth,
                              layer.textureSourceHeight,
                            ),
                            transform: layer.transform,
                            opacity: layer.opacity,
                          ),
                          backdrop: _popupBackdrop(
                            ShellTheme.of(context),
                            layer,
                          ),
                          // A client-drawn shadow lies outside the popup's
                          // window geometry and stays unfrosted.
                          materialRegion: layer.windowGeometryFraction,
                          filterQuality: filterQuality,
                          presentationScale: devicePixelRatio,
                          pixelGridOrigin: pixelGridOrigin,
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static ImageFilterConfig? _popupBackdrop(
    ShellThemeData theme,
    DenialSurfaceLayer layer,
  ) {
    final available =
        (!layer.opaque || layer.opacity < 1.0) &&
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0) &&
        theme.backdropBlurOpacityThreshold < 1;
    return available
        ? theme.backdropFilterConfigAt(1, useWindowAlphaThreshold: true)
        : null;
  }
}
