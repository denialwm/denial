import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:flutter/material.dart';

import '../state/desktop_window_switcher.dart';
import '../widgets/desktop_window_reveal.dart';
import '../widgets/desktop_window_switcher.dart';
import 'desktop_home_layout.dart';
import 'desktop_minimize_layer_handoff.dart';
import 'desktop_pixel_alignment.dart';
import 'desktop_popup_surface_layers.dart';
import 'desktop_window_frame.dart';
import 'desktop_workspace.dart';

/// [heldLayers] are the pets each window holds, keyed by the window's object
/// id (see `desktopHeldLayersByWindow`). Each window's frame draws its own,
/// inside the transforms that move it.
List<Widget> buildDesktopWindowLayers({
  bool desktopVisible = false,
  required List<DesktopWindowPlacement> placements,
  required Map<int, DenialWindow> windowsById,
  required DesktopWorkspaceState desktop,
  required bool desktopPlane,
  required DesktopMinimizeLayerHandoffController minimizeLayerHandoff,
  required DesktopMinimizedPlacementTransitionController
  minimizedPlacementTransition,
  required Map<int, Rect> minimizedPlacementExitFrames,
  required Rect minimizeOffscreenBounds,
  required MinimizedWindowPlacement minimizedWindowPlacement,
  required Map<int, Rect> desktopWidgetFrames,
  required DesktopWindowSwitcherState? switcher,
  required Rect switcherStageBounds,
  required int topZ,
  required bool reduceMotion,
  required DisplayLayout? displayLayout,
  required double devicePixelRatio,
  required DesktopWindowRevealMountRegistry windowRevealRegistry,
  required Map<int, GlobalKey> windowFrameKeys,
  required ValueChanged<DenialWindow> onActivateWindow,
  required ValueChanged<DenialWindow> onCloseWindow,
  required ValueChanged<DenialWindow> onBeginOverviewDrag,
  required void Function(DenialWindow window, Offset delta)
  onUpdateOverviewDrag,
  required ValueChanged<DenialWindow> onEndOverviewDrag,
  required ValueChanged<DenialWindow> onCancelOverviewDrag,
  Map<int, Rect> overviewEntryFrames = const <int, Rect>{},
  Map<int, Rect> overviewDepartingFrames = const <int, Rect>{},
  Map<int, List<DenialWindow>> heldLayers = const <int, List<DenialWindow>>{},
}) {
  final layers = <Widget>[];
  for (final placement in placements) {
    final overview = desktop.isInOverview(placement.objectId);
    // Windows of other workspaces leave a closing workspace overview with the
    // card they sat on, instead of disappearing as soon as it closes.
    final departingFrame = overview
        ? null
        : overviewDepartingFrames[placement.objectId];
    final departing = departingFrame != null && !placement.minimized;
    if (!placement.minimized &&
        !departing &&
        !desktop.isPlacementPresented(placement)) {
      continue;
    }
    final window = windowsById[placement.objectId]!;
    final switching =
        !overview &&
        DesktopWindowSwitcherLayout.contains(switcher, placement.objectId);
    final minimizedIdle = placement.minimized && !overview && !switching;
    final minimizingForeground =
        minimizedIdle &&
        minimizeLayerHandoff.keepsOnForeground(placement.objectId);
    final usesDesktopPlane = minimizedIdle && !minimizingForeground;
    final configuredDesktopPlacement =
        minimizedWindowPlacement == MinimizedWindowPlacement.desktop;
    final usesDesktopPlacement = minimizedPlacementTransition
        .usesDesktopPlacement(
          placement.objectId,
          configuredDesktop: configuredDesktopPlacement,
        );
    final desktopWidget =
        minimizedIdle && usesDesktopPlane && usesDesktopPlacement;
    final offscreenMinimized =
        minimizedIdle && usesDesktopPlane && !usesDesktopPlacement;
    final placementEntering = minimizedPlacementTransition.entersDesktop(
      placement.objectId,
    );
    final desktopWidgetEntering =
        desktopWidget &&
        (minimizeLayerHandoff.slidesIntoDesktop(placement.objectId) ||
            placementEntering);
    final desktopWidgetExiting =
        desktopWidget &&
        minimizedPlacementTransition.exitsDesktop(placement.objectId);
    final desktopWidgetTransitionDuration =
        placementEntering || desktopWidgetExiting
        ? Motion.desktopWindowPlacementTransition
        : Motion.desktopWindowWidgetEnter;
    final suppressPositionAnimation =
        desktopWidgetEntering ||
        (minimizedIdle &&
            minimizedPlacementTransition.commitsOffscreen(placement.objectId));
    if (usesDesktopPlane != desktopPlane) {
      continue;
    }
    final arrangedFrame = departing
        ? departingFrame
        : overview && overviewEntryFrames.containsKey(placement.objectId)
        ? overviewEntryFrames[placement.objectId]
        : minimizingForeground
        ? DesktopHomeLayout.offscreenFrame(
            bounds: minimizeOffscreenBounds,
            source: placement.frame,
          )
        : desktopWidgetExiting
        ? minimizedPlacementExitFrames[placement.objectId]
        : minimizedIdle
        ? desktopWidgetFrames[placement.objectId]
        : switching
        ? DesktopWindowSwitcherLayout.visualFrame(
            placement: placement,
            switcher: switcher,
            stageBounds: switcherStageBounds,
            desktopWidgetFrame: desktopWidgetFrames[placement.objectId],
          )
        : desktop.visualFrame(placement);
    if (arrangedFrame == null || arrangedFrame.isEmpty) {
      continue;
    }
    final outputPixelGrid = desktopOutputPixelGridForMonitor(
      displayLayout,
      placement.monitorId,
    );
    final frame = desktopPixelAlignedWindowFrame(
      frame: arrangedFrame,
      contentInset: placement.frameBorder,
      devicePixelRatio: outputPixelGrid?.scale ?? devicePixelRatio,
      pixelGridOrigin: outputPixelGrid?.logicalRect.topLeft ?? Offset.zero,
      enabled: !overview && !departing && !switching && !minimizedIdle,
      alignSize: true,
    );
    final visible =
        departing ||
        minimizingForeground ||
        desktopWidget ||
        overview ||
        (switching
            ? DesktopWindowSwitcherLayout.isVisible(
                placement: placement,
                switcher: switcher,
              )
            : !offscreenMinimized);
    final motionDuration = reduceMotion
        ? Duration.zero
        : departing
        ? Motion.overviewClose
        : minimizedIdle
        ? Motion.desktopWindowWidget
        : switching
        ? DesktopWindowSwitcherLayout.motionDuration(switcher!)
        : overview
        ? Motion.overviewOpen
        : Motion.overviewClose;
    final active = departing
        ? false
        : switching
        ? DesktopWindowSwitcherLayout.isSelected(switcher, placement.objectId)
        : overview
        ? desktop.overview?.selectedObjectId == placement.objectId
        : !placement.minimized && placement.z == topZ;
    final selected =
        overview && desktop.overview?.selectedObjectId == placement.objectId;
    // Held pets, like popups, are absent from a desktop widget and from a
    // window leaving a closing workspace overview.
    final held = desktopWidget || departing
        ? const <DenialWindow>[]
        : heldLayers[placement.objectId] ?? const <DenialWindow>[];
    layers.add(
      DesktopWindowFrame(
        key: windowFrameKeys.putIfAbsent(placement.objectId, () => GlobalKey()),
        window: window,
        placement: placement,
        frame: frame,
        minimized: !visible,
        desktopWidget: desktopWidget,
        offscreenMinimized: minimizingForeground || offscreenMinimized,
        desktopWidgetEntering: desktopWidgetEntering,
        desktopWidgetExiting: desktopWidgetExiting,
        desktopWidgetTransitionDuration: desktopWidgetTransitionDuration,
        suppressPositionAnimation: suppressPositionAnimation,
        overviewActive: desktop.overviewActive,
        overview: overview,
        overviewDeparting: departing,
        switching: switching,
        motionDuration: motionDuration,
        active: active && !desktopVisible,
        selected: selected,
        windowRevealRegistry: windowRevealRegistry,
        onOverviewTap: () => onActivateWindow(window),
        onOverviewClose: () => onCloseWindow(window),
        onOverviewDragStart: () => onBeginOverviewDrag(window),
        onOverviewDragUpdate: (delta) => onUpdateOverviewDrag(window, delta),
        onOverviewDragEnd: () => onEndOverviewDrag(window),
        onOverviewDragCancel: () => onCancelOverviewDrag(window),
        heldPets: held,
      ),
    );
    if (!desktopWidget && !departing) {
      layers.add(
        DesktopPopupSurfaceLayers(
          key: ValueKey<String>('desktop-popup-layers-${placement.objectId}'),
          window: window,
          placement: placement,
          frame: frame,
          minimized: !visible,
          offscreenMinimized: minimizingForeground || offscreenMinimized,
          overviewActive: desktop.overviewActive,
          overview: overview,
          switching: switching,
          motionDuration: motionDuration,
        ),
      );
    }
  }
  return layers;
}
