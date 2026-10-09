import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:flutter/material.dart';

import '../state/desktop_window_switcher.dart';
import '../widgets/desktop_visibility_transition.dart';
import '../widgets/desktop_window_reveal.dart';
import 'desktop_minimize_layer_handoff.dart';
import 'desktop_pixel_alignment.dart';
import 'desktop_scene_layers.dart';
import 'desktop_window_layers.dart';
import 'desktop_window_switcher_bounds.dart';
import 'desktop_workspace.dart';

/// Deliberately reuses the production window widgets. This experiment
/// measures the cost of the surrounding shell, not a new window renderer.
Widget buildDesktopWindowsOnlyScene({
  required BuildContext context,
  required Size viewSize,
  required DisplayLayout? displayLayout,
  required List<DenialWindow> layerSurfaces,
  required Map<int, List<DenialWindow>> heldLayers,
  required DesktopWorkspaceState desktop,
  required bool desktopVisible,
  required MinimizedWindowPlacement minimizedWindowPlacement,
  required DesktopWindowSwitcherState? switcher,
  required DesktopMinimizeLayerHandoffController minimizeLayerHandoff,
  required DesktopMinimizedPlacementTransitionController
  minimizedPlacementTransition,
  required Map<int, Rect> minimizedPlacementExitFrames,
  required DesktopWindowRevealMountRegistry windowRevealRegistry,
  required Map<int, GlobalKey> windowFrameKeys,
  required ValueChanged<DenialWindow> onActivateWindow,
  required ValueChanged<DenialWindow> onCloseWindow,
  required ValueChanged<DenialWindow> onBeginOverviewDrag,
  required void Function(DenialWindow window, Offset delta)
  onUpdateOverviewDrag,
  required ValueChanged<DenialWindow> onEndOverviewDrag,
  required ValueChanged<DenialWindow> onCancelOverviewDrag,
  required List<DesktopWindowPlacement> placements,
  required Map<int, DenialWindow> windowsById,
  required List<DenialWindow> popupSurfaces,
  required int topZ,
}) {
  final canvas = Offset.zero & viewSize;
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return Stack(
    fit: StackFit.expand,
    children: [
      // Keep the original no-wallpaper baseline available independently of
      // the wallpaper-backed scene used to inspect window shadows.
      if (desktopDiagnosticWallpaper) const ShellWallpaper(),
      // A held layer is drawn in its window's slot instead.
      for (final surface in layerSurfaces)
        if (!surface.isHeld &&
            (surface.contentKind ==
                    DenialWindowContentKind.layerShellBackground ||
                surface.contentKind ==
                    DenialWindowContentKind.layerShellBottom))
          DesktopLayerShellSurface(
            key: ValueKey<String>('layer-shell-${surface.surfaceId}'),
            surface: surface,
            displayLayout: displayLayout,
          ),
      ...buildDesktopWindowLayers(
        desktopVisible: desktopVisible,
        placements: placements,
        windowsById: windowsById,
        desktop: desktop,
        desktopPlane: false,
        minimizeLayerHandoff: minimizeLayerHandoff,
        minimizedPlacementTransition: minimizedPlacementTransition,
        minimizedPlacementExitFrames: minimizedPlacementExitFrames,
        minimizeOffscreenBounds: canvas,
        minimizedWindowPlacement: minimizedWindowPlacement,
        desktopWidgetFrames: const <int, Rect>{},
        switcher: switcher,
        switcherStageBounds: switcher == null
            ? Rect.zero
            : desktopWindowSwitcherStageBounds(
                viewSize: viewSize,
                displayLayout: displayLayout,
                desktop: desktop,
                switcher: switcher,
              ),
        topZ: topZ,
        reduceMotion: reduceMotion,
        displayLayout: displayLayout,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        windowRevealRegistry: windowRevealRegistry,
        windowFrameKeys: windowFrameKeys,
        onActivateWindow: onActivateWindow,
        onCloseWindow: onCloseWindow,
        onBeginOverviewDrag: onBeginOverviewDrag,
        onUpdateOverviewDrag: onUpdateOverviewDrag,
        onEndOverviewDrag: onEndOverviewDrag,
        onCancelOverviewDrag: onCancelOverviewDrag,
        heldLayers: heldLayers,
      ),
      for (final popup in popupSurfaces)
        if (popup.geometry case final geometry?)
          Positioned.fromRect(
            key: ValueKey<String>('desktop-popup-surface-${popup.objectId}'),
            rect: geometry,
            child: DesktopVisibilityTransition(
              child: IgnorePointer(
                child: WindowSurfaceTree(
                  window: popup,
                  includePopups: true,
                  presentationScale: desktopOutputPixelGridForMonitor(
                    displayLayout,
                    popup.monitorId,
                  )?.scale,
                  pixelGridOrigin:
                      desktopOutputPixelGridForMonitor(
                        displayLayout,
                        popup.monitorId,
                      )?.logicalRect.topLeft ??
                      Offset.zero,
                ),
              ),
            ),
          ),
      for (final surface in layerSurfaces)
        if (!surface.isHeld &&
            (surface.contentKind == DenialWindowContentKind.layerShellTop ||
                surface.contentKind ==
                    DenialWindowContentKind.layerShellOverlay))
          DesktopLayerShellSurface(
            key: ValueKey<String>('layer-shell-${surface.surfaceId}'),
            surface: surface,
            displayLayout: displayLayout,
          ),
    ],
  );
}
