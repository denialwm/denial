import 'dart:async';
import 'dart:math' as math;

import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/surface_hosting.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/shell_plugin_services.dart';
import '../features/default_shell/panel_composition.dart';
import '../state/clipboard_tray.dart';
import '../state/desktop_visibility.dart';
import '../state/desktop_window_switcher.dart';
import '../wallpaper/widgets/wallpaper_selector_surface.dart';
import '../widgets/clipboard_tray_layer.dart';
import '../widgets/desktop_visibility_transition.dart';
import '../widgets/desktop_window_reveal.dart';
import '../widgets/desktop_window_switcher.dart';
import '../widgets/shell_frame_time_overlay.dart';
import 'desktop_held_layers.dart';
import 'desktop_home_layout.dart';
import 'desktop_minimize_layer_handoff.dart';
import 'desktop_panel_overlay.dart';
import 'desktop_pixel_alignment.dart';
import 'desktop_scene_layers.dart';
import 'desktop_window_frame.dart';
import 'desktop_window_layers.dart';
import 'desktop_window_switcher_bounds.dart';
import 'desktop_windows_only_scene.dart';
import 'desktop_workspace.dart';
import 'desktop_workspace_overview_deck.dart';
import 'retained_animated_positioned.dart';
import 'system_tray_module.dart';

typedef _DesktopSceneTopology = ({
  Map<int, DenialWindow> windowsById,
  List<DenialWindow> popupSurfaces,
  List<DesktopWindowPlacement> placements,
  int topZ,
});

class _DesktopSceneTopologyCache {
  const _DesktopSceneTopologyCache({
    required this.windows,
    required this.placementMap,
    required this.windowSwitcher,
    required this.topology,
  });

  final List<DenialWindow> windows;
  final Map<int, DesktopWindowPlacement> placementMap;
  final DesktopWindowSwitcherState? windowSwitcher;
  final _DesktopSceneTopology topology;

  bool matches(
    List<DenialWindow> windows,
    Map<int, DesktopWindowPlacement> placementMap,
    DesktopWindowSwitcherState? windowSwitcher,
  ) {
    return identical(this.windows, windows) &&
        identical(this.placementMap, placementMap) &&
        identical(this.windowSwitcher, windowSwitcher);
  }
}

typedef _DesktopHomeSceneLayout = ({Map<int, Rect> windowFrames});

typedef _DesktopHomePlacementSignature = ({
  Rect frame,
  int monitorId,
  int z,
  bool fullscreen,
  bool serverSideDecorated,
});

class _DesktopHomeLayoutCache {
  _DesktopHomeLayoutCache({
    required this.viewSize,
    required this.displayLayout,
    required this.minimizedWindowPlacement,
    required Iterable<DesktopWindowPlacement> placements,
    required List<Rect> occupiedBounds,
    required this.layout,
  }) : minimizedPlacements = <int, _DesktopHomePlacementSignature>{
         for (final placement in placements)
           if (placement.minimized)
             placement.objectId: (
               frame: placement.frame,
               monitorId: placement.monitorId,
               z: placement.z,
               fullscreen: placement.fullscreen,
               serverSideDecorated: placement.serverSideDecorated,
             ),
       },
       occupiedBounds = List.unmodifiable(occupiedBounds);

  final Size viewSize;
  final DisplayLayout? displayLayout;
  final MinimizedWindowPlacement minimizedWindowPlacement;
  final Map<int, _DesktopHomePlacementSignature> minimizedPlacements;
  final List<Rect> occupiedBounds;
  final _DesktopHomeSceneLayout layout;

  bool matches({
    required Size viewSize,
    required DisplayLayout? displayLayout,
    required MinimizedWindowPlacement minimizedWindowPlacement,
    required Iterable<DesktopWindowPlacement> placements,
    required List<Rect> occupiedBounds,
  }) {
    if (this.viewSize != viewSize ||
        !identical(this.displayLayout, displayLayout) ||
        this.minimizedWindowPlacement != minimizedWindowPlacement) {
      return false;
    }

    var minimizedCount = 0;
    for (final placement in placements) {
      if (!placement.minimized) {
        continue;
      }
      minimizedCount += 1;
      final cached = minimizedPlacements[placement.objectId];
      if (cached == null ||
          cached.frame != placement.frame ||
          cached.monitorId != placement.monitorId ||
          cached.z != placement.z ||
          cached.fullscreen != placement.fullscreen ||
          cached.serverSideDecorated != placement.serverSideDecorated) {
        return false;
      }
    }
    if (minimizedCount != minimizedPlacements.length) {
      return false;
    }

    return listEquals(this.occupiedBounds, occupiedBounds);
  }
}

String _desktopHomeWindowKey(int objectId) => 'home-window:$objectId';

_DesktopHomeSceneLayout _layoutDesktopHome({
  required Size viewSize,
  required DisplayLayout? displayLayout,
  required MinimizedWindowPlacement minimizedWindowPlacement,
  required Iterable<DesktopWindowPlacement> placements,
  required List<Rect> occupiedBounds,
}) {
  final canvas = Offset.zero & viewSize;
  if (canvas.isEmpty) {
    return (windowFrames: const <int, Rect>{});
  }

  final minimized =
      placements
          .where((placement) => placement.minimized)
          .toList(growable: false)
        ..sort((left, right) {
          final zOrder = left.z.compareTo(right.z);
          return zOrder != 0 ? zOrder : left.objectId.compareTo(right.objectId);
        });
  final nativeOutputs = displayLayout?.outputs ?? const <DisplayOutput>[];
  final outputAreas = <({int monitorId, Rect bounds})>[
    for (final output in nativeOutputs)
      if ((displayLayout?.workAreaOf(output) ?? output.logicalRect).intersect(
            canvas,
          )
          case final bounds when !bounds.isEmpty)
        (monitorId: output.monitorId, bounds: bounds),
  ];
  if (outputAreas.isEmpty) {
    outputAreas.add((
      monitorId: minimized.isEmpty ? 0 : minimized.first.monitorId,
      bounds: canvas,
    ));
  }
  final mainMonitorId =
      displayLayout?.mainOutput?.monitorId ?? outputAreas.first.monitorId;
  final fallbackArea = outputAreas.firstWhere(
    (area) => area.monitorId == mainMonitorId,
    orElse: () => outputAreas.first,
  );
  final placementsByMonitor = <int, List<DesktopWindowPlacement>>{};
  for (final placement in minimized) {
    ({int monitorId, Rect bounds})? area;
    for (final candidate in outputAreas) {
      if (candidate.monitorId == placement.monitorId) {
        area = candidate;
        break;
      }
    }
    if (area == null) {
      for (final candidate in outputAreas) {
        if (candidate.bounds.contains(placement.frame.center)) {
          area = candidate;
          break;
        }
      }
    }
    area ??= fallbackArea;
    placementsByMonitor
        .putIfAbsent(area.monitorId, () => <DesktopWindowPlacement>[])
        .add(placement);
  }

  final windowFrames = <int, Rect>{};
  final showMinimizedWindowsOnDesktop =
      minimizedWindowPlacement == MinimizedWindowPlacement.desktop;
  for (final area in outputAreas) {
    final outputWindows = showMinimizedWindowsOnDesktop
        ? placementsByMonitor[area.monitorId] ??
              const <DesktopWindowPlacement>[]
        : const <DesktopWindowPlacement>[];
    final denseWindowMode = DesktopHomeLayout.usesDenseWindowMode(
      outputWindows.length,
    );
    final frames = DesktopHomeLayout.arrange(
      bounds: _unoccupiedDesktopArea(area.bounds, occupiedBounds),
      dense: denseWindowMode,
      items: <DesktopHomeLayoutItem>[
        for (final placement in outputWindows)
          DesktopHomeLayoutItem(
            id: _desktopHomeWindowKey(placement.objectId),
            contentAspectRatio:
                placement.contentRect.width / placement.contentRect.height,
            frameInset: placement.serverSideDecorated
                ? DesktopMetrics.frameBorder
                : 0.0,
          ),
      ],
    );
    for (final placement in outputWindows) {
      final frame = frames[_desktopHomeWindowKey(placement.objectId)];
      if (frame != null) {
        windowFrames[placement.objectId] = frame;
      }
    }
  }
  if (!showMinimizedWindowsOnDesktop) {
    for (final placement in minimized) {
      windowFrames[placement.objectId] = DesktopHomeLayout.offscreenFrame(
        bounds: canvas,
        source: placement.frame,
      );
    }
  }
  return (windowFrames: Map<int, Rect>.unmodifiable(windowFrames));
}

class DesktopScene extends ConsumerStatefulWidget {
  const DesktopScene({
    super.key,
    required this.viewSize,
    required this.windows,
    required this.layerSurfaces,
    required this.desktop,
    required this.closeEffect,
    required this.minimizedWindowPlacement,
    required this.panelTravel,
    required this.panelDurationScale,
    required this.windowSwitcher,
    required this.displayLayout,
    required this.showFrameTimingOverlay,
    required this.wallpaperSelectorVisible,
    required this.shellOutputRect,
    required this.mainOutputRect,
    required this.applicationSearchFocusNode,
    required this.onOpenLauncher,
    required this.onDismissLauncher,
    required this.onOpenDashboard,
    required this.onCloseWallpaperSelector,
    required this.onOpenSettings,
    required this.onOpenPowerSettings,
    required this.onToggleLauncher,
    required this.onCancelPanelClose,
    required this.onSchedulePanelClose,
    required this.onPanelOpened,
    required this.onLaunchApp,
    required this.onLaunchLocalApp,
    required this.onActivateWindow,
    required this.onCloseWindow,
    required this.onOverviewBarrierTap,
    required this.onSelectOverviewWorkspace,
    required this.onBeginOverviewDrag,
    required this.onUpdateOverviewDrag,
    required this.onEndOverviewDrag,
    required this.onCancelOverviewDrag,
    required this.onCloseLeaseComplete,
  });

  final Size viewSize;
  final List<DenialWindow> windows;
  final List<DenialWindow> layerSurfaces;
  final DesktopWorkspaceState desktop;
  final DesktopWindowCloseEffect closeEffect;
  final MinimizedWindowPlacement minimizedWindowPlacement;
  final double panelTravel;
  final double panelDurationScale;
  final DesktopWindowSwitcherState? windowSwitcher;
  final DisplayLayout? displayLayout;
  final bool showFrameTimingOverlay;
  final bool wallpaperSelectorVisible;
  final Rect? shellOutputRect;
  final Rect? mainOutputRect;
  final FocusNode applicationSearchFocusNode;
  final VoidCallback onOpenLauncher;
  final VoidCallback onDismissLauncher;
  final VoidCallback onOpenDashboard;
  final VoidCallback onCloseWallpaperSelector;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPowerSettings;
  final VoidCallback onToggleLauncher;
  final VoidCallback onCancelPanelClose;
  final VoidCallback onSchedulePanelClose;
  final VoidCallback onPanelOpened;
  final ValueChanged<DesktopApp> onLaunchApp;
  final ValueChanged<LocalFlutterApplication> onLaunchLocalApp;
  final ValueChanged<DenialWindow> onActivateWindow;
  final ValueChanged<DenialWindow> onCloseWindow;
  final ValueChanged<Offset> onOverviewBarrierTap;
  final void Function(int monitorId, int workspaceId) onSelectOverviewWorkspace;
  final ValueChanged<DenialWindow> onBeginOverviewDrag;
  final void Function(DenialWindow window, Offset delta) onUpdateOverviewDrag;
  final ValueChanged<DenialWindow> onEndOverviewDrag;
  final ValueChanged<DenialWindow> onCancelOverviewDrag;
  final ValueChanged<int> onCloseLeaseComplete;

  @override
  ConsumerState<DesktopScene> createState() => _DesktopSceneState();
}

class _DesktopSceneState extends ConsumerState<DesktopScene> {
  final Map<int, ClosingDesktopWindow> _closingWindows =
      <int, ClosingDesktopWindow>{};
  final Map<int, Rect> _minimizedPlacementExitFrames = <int, Rect>{};
  // Overview and restore move minimized windows between sibling scene planes.
  // Retain the whole frame subtree so its position and opacity tweens survive.
  final Map<int, GlobalKey> _windowFrameKeys = <int, GlobalKey>{};
  final DesktopWindowRevealMountRegistry _windowRevealRegistry =
      DesktopWindowRevealMountRegistry();
  late final DesktopMinimizeLayerHandoffController _minimizeLayerHandoff;
  late final DesktopMinimizedPlacementTransitionController
  _minimizedPlacementTransition;
  int _nextCloseId = 1;
  _DesktopHomeLayoutCache? _homeLayoutCache;
  _DesktopSceneTopologyCache? _topologyCache;
  // A workspace overview behaves like a camera over every workspace. Windows
  // of other workspaces enter from beside the screen and leave the same way,
  // so they need a frame outside the scene's ordinary presented set.
  Map<int, Rect> _overviewEntryFrames = const <int, Rect>{};
  Map<int, Rect> _overviewDepartingFrames = const <int, Rect>{};
  Timer? _overviewDepartureTimer;
  List<DenialWindow>? _heldLayersSource;
  Map<int, List<DenialWindow>> _heldLayers = const <int, List<DenialWindow>>{};

  @override
  void initState() {
    super.initState();
    _minimizeLayerHandoff = DesktopMinimizeLayerHandoffController(
      handoffDelay: Motion.desktopWindowLayerHandoff,
      desktopEntryDuration: Motion.desktopWindowWidgetEnter,
      onChanged: () {
        if (mounted) {
          setState(() {});
        }
      },
    );
    _minimizedPlacementTransition =
        DesktopMinimizedPlacementTransitionController(
          duration: Motion.desktopWindowPlacementTransition,
          onChanged: () {
            if (!mounted) {
              return;
            }
            _minimizedPlacementExitFrames.removeWhere(
              (objectId, _) =>
                  !_minimizedPlacementTransition.exitsDesktop(objectId),
            );
            setState(() {});
          },
        );
  }

  /// Layer surfaces held by windows, which are drawn in their window's slot
  /// instead of in their layer plane.
  Map<int, List<DenialWindow>> _cachedHeldLayers(
    List<DenialWindow> layerSurfaces,
  ) {
    if (!identical(_heldLayersSource, layerSurfaces)) {
      _heldLayersSource = layerSurfaces;
      _heldLayers = desktopHeldLayersByWindow(layerSurfaces);
    }
    return _heldLayers;
  }

  _DesktopSceneTopology _cachedTopology({
    required List<DenialWindow> windows,
    required Map<int, DesktopWindowPlacement> placementMap,
    required DesktopWindowSwitcherState? windowSwitcher,
  }) {
    final cached = _topologyCache;
    if (cached != null &&
        cached.matches(windows, placementMap, windowSwitcher)) {
      return cached.topology;
    }
    final windowsById = <int, DenialWindow>{
      for (final window in windows) window.objectId: window,
    };
    final popupSurfaces = windows
        .where((window) => window.isPopupSurface)
        .toList(growable: false);
    final placements =
        placementMap.values
            .where((placement) => windowsById.containsKey(placement.objectId))
            .toList(growable: false)
          ..sort(
            (a, b) => DesktopWindowSwitcherLayout.compare(
              a,
              b,
              windowsById,
              windowSwitcher,
            ),
          );
    final topology = (
      windowsById: windowsById,
      popupSurfaces: popupSurfaces,
      placements: placements,
      topZ: placements
          .where((placement) => !placement.minimized)
          .fold<int>(0, (value, placement) => math.max(value, placement.z)),
    );
    _topologyCache = _DesktopSceneTopologyCache(
      windows: windows,
      placementMap: placementMap,
      windowSwitcher: windowSwitcher,
      topology: topology,
    );
    return topology;
  }

  void _updateWorkspaceOverviewMotion(
    DesktopWorkspaceState previous,
    DesktopWorkspaceState next,
  ) {
    final before = previous.overview;
    final after = next.overview;
    if (identical(before, after)) {
      return;
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final opened = after?.workspaces;
    if (opened != null && before?.workspaces == null) {
      final departing = _overviewDepartingFrames;
      _overviewDepartureTimer?.cancel();
      _overviewDepartingFrames = const <int, Rect>{};
      if (reduceMotion) {
        return;
      }
      final camera = next.activeWorkspaceFor(after!.monitorId);
      final entries = <int, Rect>{
        for (final entry in after.frames.entries)
          if (next.placements[entry.key] case final placement?)
            if (!placement.minimized &&
                !departing.containsKey(entry.key) &&
                !previous.isPlacementPresented(placement))
              entry.key: opened.cameraRect(entry.value, camera),
      };
      if (entries.isEmpty) {
        return;
      }
      _overviewEntryFrames = entries;
      // Mount at the camera position for one frame, then travel to the card.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_overviewEntryFrames, entries)) {
          setState(() => _overviewEntryFrames = const <int, Rect>{});
        }
      });
      return;
    }
    final closed = before?.workspaces;
    if (closed == null || after?.workspaces != null) {
      return;
    }
    _overviewEntryFrames = const <int, Rect>{};
    _overviewDepartureTimer?.cancel();
    if (reduceMotion) {
      _overviewDepartingFrames = const <int, Rect>{};
      return;
    }
    final camera = next.activeWorkspaceFor(before!.monitorId);
    _overviewDepartingFrames = <int, Rect>{
      for (final entry in before.frames.entries)
        if (next.placements[entry.key] case final placement?)
          if (!placement.minimized &&
              !next.isInOverview(entry.key) &&
              !next.isPlacementPresented(placement))
            entry.key: closed.cameraRect(entry.value, camera),
    };
    if (_overviewDepartingFrames.isEmpty) {
      return;
    }
    _overviewDepartureTimer = Timer(Motion.overviewClose, () {
      if (mounted) {
        setState(() => _overviewDepartingFrames = const <int, Rect>{});
      }
    });
  }

  @override
  void didUpdateWidget(covariant DesktopScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateWorkspaceOverviewMotion(oldWidget.desktop, widget.desktop);

    final activeObjectIds = <int>{
      for (final window in widget.windows) window.objectId,
    };
    _windowRevealRegistry.retainOnly(activeObjectIds);
    _windowFrameKeys.removeWhere(
      (objectId, _) => !activeObjectIds.contains(objectId),
    );
    _minimizeLayerHandoff.retainOnly(activeObjectIds);
    final animateMinimize = !MediaQuery.disableAnimationsOf(context);
    for (final placement in widget.desktop.placements.values) {
      final previous = oldWidget.desktop.placements[placement.objectId];
      if (!placement.minimized) {
        _minimizeLayerHandoff.cancel(placement.objectId);
      } else if (previous?.minimized == false) {
        _minimizeLayerHandoff.begin(
          placement.objectId,
          animate: animateMinimize,
        );
      }
    }
    final minimizedObjectIds = <int>{
      for (final placement in widget.desktop.placements.values)
        if (placement.minimized && activeObjectIds.contains(placement.objectId))
          placement.objectId,
    };
    _minimizedPlacementTransition.retainOnly(minimizedObjectIds);
    _minimizedPlacementExitFrames.removeWhere(
      (objectId, _) => !minimizedObjectIds.contains(objectId),
    );
    if (oldWidget.minimizedWindowPlacement != widget.minimizedWindowPlacement) {
      final settledObjectIds = minimizedObjectIds
          .where(
            (objectId) => !_minimizeLayerHandoff.keepsOnForeground(objectId),
          )
          .toSet();
      final toDesktop =
          widget.minimizedWindowPlacement == MinimizedWindowPlacement.desktop;
      if (toDesktop) {
        _minimizedPlacementExitFrames.clear();
        _minimizedPlacementTransition.begin(
          settledObjectIds,
          toDesktop: true,
          animate: animateMinimize,
        );
      } else if (animateMinimize) {
        final previousFrames =
            _homeLayoutCache?.layout.windowFrames ?? const <int, Rect>{};
        _minimizedPlacementExitFrames
          ..clear()
          ..addEntries(
            settledObjectIds
                .where(previousFrames.containsKey)
                .map(
                  (objectId) => MapEntry(objectId, previousFrames[objectId]!),
                ),
          );
        _minimizedPlacementTransition.begin(
          _minimizedPlacementExitFrames.keys,
          toDesktop: false,
          animate: true,
        );
      } else {
        _minimizedPlacementExitFrames.clear();
        _minimizedPlacementTransition.begin(
          const <int>[],
          toDesktop: false,
          animate: false,
        );
      }
    }
    for (final window in oldWidget.windows.where(
      (window) => window.isUserApp,
    )) {
      if (activeObjectIds.contains(window.objectId)) {
        continue;
      }
      final placement = oldWidget.desktop.placements[window.objectId];
      if (widget.closeEffect == DesktopWindowCloseEffect.none ||
          !window.isUserApp ||
          window.suppressAnimations ||
          placement == null ||
          placement.minimized) {
        widget.onCloseLeaseComplete(window.windowId);
        continue;
      }
      final frame = oldWidget.desktop.visualFrame(placement);
      if (frame.isEmpty) {
        widget.onCloseLeaseComplete(window.windowId);
        continue;
      }
      final closeId = _nextCloseId++;
      final outputClip = desktopOutputClip(
        activelyDragging: placement.dragging,
        outputRect: desktopOutputPixelGridForMonitor(
          oldWidget.displayLayout,
          placement.monitorId,
        )?.logicalRect,
      );
      _closingWindows[closeId] = ClosingDesktopWindow(
        id: closeId,
        window: window,
        frame: frame,
        fullscreen:
            placement.fullscreen &&
            !oldWidget.desktop.isInOverview(window.objectId),
        effect: widget.closeEffect,
        outputClip: outputClip,
      );
    }
  }

  void _completeCloseAnimation(int closeId) {
    if (!mounted) {
      return;
    }
    final closing = _closingWindows[closeId];
    if (closing == null) {
      return;
    }
    setState(() => _closingWindows.remove(closeId));
    widget.onCloseLeaseComplete(closing.window.windowId);
  }

  _DesktopHomeSceneLayout _cachedDesktopHomeLayout({
    required Size viewSize,
    required DisplayLayout? displayLayout,
    required MinimizedWindowPlacement minimizedWindowPlacement,
    required Iterable<DesktopWindowPlacement> placements,
    required List<Rect> occupiedBounds,
  }) {
    final cached = _homeLayoutCache;
    if (cached != null &&
        cached.matches(
          viewSize: viewSize,
          displayLayout: displayLayout,
          minimizedWindowPlacement: minimizedWindowPlacement,
          placements: placements,
          occupiedBounds: occupiedBounds,
        )) {
      return cached.layout;
    }
    final layout = _layoutDesktopHome(
      viewSize: viewSize,
      displayLayout: displayLayout,
      minimizedWindowPlacement: minimizedWindowPlacement,
      placements: placements,
      occupiedBounds: occupiedBounds,
    );
    _homeLayoutCache = _DesktopHomeLayoutCache(
      viewSize: viewSize,
      displayLayout: displayLayout,
      minimizedWindowPlacement: minimizedWindowPlacement,
      placements: placements,
      occupiedBounds: occupiedBounds,
      layout: layout,
    );
    return layout;
  }

  @override
  void dispose() {
    _overviewDepartureTimer?.cancel();
    _minimizeLayerHandoff.dispose();
    _minimizedPlacementTransition.dispose();
    _minimizedPlacementExitFrames.clear();
    for (final closing in _closingWindows.values) {
      widget.onCloseLeaseComplete(closing.window.windowId);
    }
    _closingWindows.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = widget.viewSize;
    final windows = widget.windows;
    final layerSurfaces = widget.layerSurfaces;
    final heldLayers = _cachedHeldLayers(layerSurfaces);
    final desktop = widget.desktop;
    final windowSwitcher = widget.windowSwitcher;
    final displayLayout = widget.displayLayout;
    final minimizedWindowPlacement = widget.minimizedWindowPlacement;
    final showFrameTimingOverlay = widget.showFrameTimingOverlay;
    final wallpaperSelectorVisible = widget.wallpaperSelectorVisible;
    final shellOutputRect = widget.shellOutputRect;
    final mainOutputRect = widget.mainOutputRect;
    final applicationSearchFocusNode = widget.applicationSearchFocusNode;
    final onOpenLauncher = widget.onOpenLauncher;
    final onDismissLauncher = widget.onDismissLauncher;
    final onOpenDashboard = widget.onOpenDashboard;
    final onOpenSettings = widget.onOpenSettings;
    final onOpenPowerSettings = widget.onOpenPowerSettings;
    final onCloseWallpaperSelector = widget.onCloseWallpaperSelector;
    final onCancelPanelClose = widget.onCancelPanelClose;
    final onSchedulePanelClose = widget.onSchedulePanelClose;
    final onCloseWindow = widget.onCloseWindow;
    final onLaunchApp = widget.onLaunchApp;
    final onLaunchLocalApp = widget.onLaunchLocalApp;
    final onActivateWindow = widget.onActivateWindow;
    final onOverviewBarrierTap = widget.onOverviewBarrierTap;
    final onBeginOverviewDrag = widget.onBeginOverviewDrag;
    final onUpdateOverviewDrag = widget.onUpdateOverviewDrag;
    final onEndOverviewDrag = widget.onEndOverviewDrag;
    final onCancelOverviewDrag = widget.onCancelOverviewDrag;
    final topology = _cachedTopology(
      windows: windows,
      placementMap: desktop.placements,
      windowSwitcher: windowSwitcher,
    );
    final windowsById = topology.windowsById;
    final desktopVisible = ref.watch(desktopVisibleProvider);
    final popupSurfaces = topology.popupSurfaces;
    final placements = topology.placements
        .where(
          (placement) =>
              placement.minimized ||
              desktop.isPlacementPresented(placement) ||
              _overviewDepartingFrames.containsKey(placement.objectId),
        )
        .toList(growable: false);
    final topZ = placements
        .where(
          (placement) =>
              !placement.minimized &&
              desktop.isPlacementOnActiveWorkspace(placement),
        )
        .fold<int>(0, (value, placement) => math.max(value, placement.z));
    if (desktopWindowsOnly) {
      return buildDesktopWindowsOnlyScene(
        context: context,
        viewSize: viewSize,
        displayLayout: displayLayout,
        layerSurfaces: layerSurfaces,
        heldLayers: heldLayers,
        desktop: desktop,
        desktopVisible: desktopVisible,
        minimizedWindowPlacement: minimizedWindowPlacement,
        switcher: windowSwitcher,
        minimizeLayerHandoff: _minimizeLayerHandoff,
        minimizedPlacementTransition: _minimizedPlacementTransition,
        minimizedPlacementExitFrames: _minimizedPlacementExitFrames,
        windowRevealRegistry: _windowRevealRegistry,
        windowFrameKeys: _windowFrameKeys,
        onActivateWindow: onActivateWindow,
        onCloseWindow: onCloseWindow,
        onBeginOverviewDrag: onBeginOverviewDrag,
        onUpdateOverviewDrag: onUpdateOverviewDrag,
        onEndOverviewDrag: onEndOverviewDrag,
        onCancelOverviewDrag: onCancelOverviewDrag,
        placements: placements,
        windowsById: windowsById,
        popupSurfaces: popupSurfaces,
        topZ: topZ,
      );
    }
    final surfaceLayout =
        displayLayout ??
        DisplayLayout.fallback(
          viewSize,
          MediaQuery.devicePixelRatioOf(context),
        );
    final surfaceSettings = ref.watch(shellSettingsProvider);
    final fullscreenMonitorIds = <int>{
      for (final placement in placements)
        if (placement.fullscreen &&
            !placement.minimized &&
            desktop.isPlacementOnActiveWorkspace(placement))
          placement.monitorId,
    };
    final surfaceEntries = resolveShellSurfaces(
      ref.watch(desktopSurfacesProvider),
      [
        for (final output in surfaceLayout.outputs)
          ShellSurfaceEnvironment(
            output: output,
            workArea: surfaceLayout.workAreaOf(output),
            isMainOutput:
                output.monitorId == surfaceLayout.mainOutput?.monitorId,
            defaultOutputSelected: surfaceLayout.hostsSystemBar(output),
            workspaceId: desktop.activeWorkspaceFor(output.monitorId),
            fullscreen: fullscreenMonitorIds.contains(output.monitorId),
            overview: desktop.overviewActive,
            desktopVisible: desktopVisible,
            wallpaperSelectorVisible: wallpaperSelectorVisible,
            locked: ref.watch(
              referenceShellProvider.select((state) => state.lockLayerVisible),
            ),
            settings: surfaceSettings,
          ),
      ],
    );
    final surfaceServices = DesktopShellServices(
      ref: ref,
      onOpenPowerSettings: onOpenPowerSettings,
      onToggleLauncher: widget.onToggleLauncher,
    );
    Widget surfacePlane(ShellSurfaceLayer layer) => ShellSurfacePlane(
      key: ValueKey(layer),
      entries: surfaceEntries,
      layer: layer,
      services: surfaceServices,
    );
    final homeLayout = _cachedDesktopHomeLayout(
      viewSize: viewSize,
      displayLayout: displayLayout,
      minimizedWindowPlacement: minimizedWindowPlacement,
      placements: placements,
      occupiedBounds: [
        for (final entry in surfaceEntries)
          if (entry.placement.occupiesDesktop && entry.placement.visible)
            entry.placement.bounds,
      ],
    );
    final canvas = Offset.zero & viewSize;
    final requestedDisplayRect = mainOutputRect?.intersect(canvas);
    final mainDisplayRect =
        requestedDisplayRect == null || requestedDisplayRect.isEmpty
        ? canvas
        : requestedDisplayRect;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final selectorMotionDuration = reduceMotion
        ? Duration.zero
        : Motion.wallpaperSelector;
    final switcherStageBounds = windowSwitcher == null
        ? Rect.zero
        : desktopWindowSwitcherStageBounds(
            viewSize: viewSize,
            displayLayout: displayLayout,
            desktop: desktop,
            switcher: windowSwitcher,
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        const ShellWallpaper(),
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
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              surfacePlane(ShellSurfaceLayer.desktop),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: wallpaperSelectorVisible,
                  child: AnimatedOpacity(
                    opacity: wallpaperSelectorVisible ? 0 : 1,
                    duration: selectorMotionDuration,
                    curve: Motion.md3EmphasizedAccelerate,
                    child: Stack(
                      fit: StackFit.expand,
                      children: buildDesktopWindowLayers(
                        desktopVisible: desktopVisible,
                        placements: placements,
                        windowsById: windowsById,
                        desktop: desktop,
                        desktopPlane: true,
                        minimizeLayerHandoff: _minimizeLayerHandoff,
                        minimizedPlacementTransition:
                            _minimizedPlacementTransition,
                        minimizedPlacementExitFrames:
                            _minimizedPlacementExitFrames,
                        minimizeOffscreenBounds: canvas,
                        minimizedWindowPlacement: minimizedWindowPlacement,
                        desktopWidgetFrames: homeLayout.windowFrames,
                        switcher: windowSwitcher,
                        switcherStageBounds: switcherStageBounds,
                        topZ: topZ,
                        reduceMotion: reduceMotion,
                        displayLayout: displayLayout,
                        devicePixelRatio: devicePixelRatio,
                        windowRevealRegistry: _windowRevealRegistry,
                        windowFrameKeys: _windowFrameKeys,
                        onActivateWindow: onActivateWindow,
                        onCloseWindow: onCloseWindow,
                        onBeginOverviewDrag: onBeginOverviewDrag,
                        onUpdateOverviewDrag: onUpdateOverviewDrag,
                        onEndOverviewDrag: onEndOverviewDrag,
                        onCancelOverviewDrag: onCancelOverviewDrag,
                        overviewEntryFrames: _overviewEntryFrames,
                        overviewDepartingFrames: _overviewDepartingFrames,
                        heldLayers: heldLayers,
                      ),
                    ),
                  ),
                ),
              ),
              DesktopOverviewInputLayer(
                // Minimized windows move between the sibling scene planes.
                // Preserve the bar's state when that changes this index.
                key: const ValueKey<String>('desktop-overview-input-layer'),
                active: desktop.overviewActive,
                onBarrierTap: onOverviewBarrierTap,
                decoration: DesktopWorkspaceOverviewDeck(
                  desktop: desktop,
                  onSelectWorkspace: widget.onSelectOverviewWorkspace,
                ),
                foregroundControls: <Widget>[
                  surfacePlane(ShellSurfaceLayer.desktopControls),
                ],
              ),
              if (windowSwitcher != null)
                DesktopWindowSwitcherBackdrop(
                  switcher: windowSwitcher,
                  bounds: switcherStageBounds,
                ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: wallpaperSelectorVisible,
                  child: AnimatedOpacity(
                    opacity: wallpaperSelectorVisible ? 0 : 1,
                    duration: selectorMotionDuration,
                    curve: Motion.md3EmphasizedAccelerate,
                    child: Stack(
                      fit: StackFit.expand,
                      children: buildDesktopWindowLayers(
                        desktopVisible: desktopVisible,
                        placements: placements,
                        windowsById: windowsById,
                        desktop: desktop,
                        desktopPlane: false,
                        minimizeLayerHandoff: _minimizeLayerHandoff,
                        minimizedPlacementTransition:
                            _minimizedPlacementTransition,
                        minimizedPlacementExitFrames:
                            _minimizedPlacementExitFrames,
                        minimizeOffscreenBounds: canvas,
                        minimizedWindowPlacement: minimizedWindowPlacement,
                        desktopWidgetFrames: homeLayout.windowFrames,
                        switcher: windowSwitcher,
                        switcherStageBounds: switcherStageBounds,
                        topZ: topZ,
                        reduceMotion: reduceMotion,
                        displayLayout: displayLayout,
                        devicePixelRatio: devicePixelRatio,
                        windowRevealRegistry: _windowRevealRegistry,
                        windowFrameKeys: _windowFrameKeys,
                        onActivateWindow: onActivateWindow,
                        onCloseWindow: onCloseWindow,
                        onBeginOverviewDrag: onBeginOverviewDrag,
                        onUpdateOverviewDrag: onUpdateOverviewDrag,
                        onEndOverviewDrag: onEndOverviewDrag,
                        onCancelOverviewDrag: onCancelOverviewDrag,
                        overviewEntryFrames: _overviewEntryFrames,
                        overviewDepartingFrames: _overviewDepartingFrames,
                        heldLayers: heldLayers,
                      ),
                    ),
                  ),
                ),
              ),
              for (final closing in _closingWindows.values)
                Positioned.fromRect(
                  key: ValueKey<String>('desktop-closing-window-${closing.id}'),
                  rect: closing.frame,
                  child: DesktopVisibilityTransition(
                    child: DesktopClosingWindowFrame(
                      closing: closing,
                      onCompleted: () => _completeCloseAnimation(closing.id),
                    ),
                  ),
                ),
              if (windowSwitcher != null)
                DesktopWindowSwitcherLayer(
                  key: ValueKey<String>(
                    'desktop-window-switcher-${windowSwitcher.sessionId}',
                  ),
                  switcher: windowSwitcher,
                  selectedWindow: windowsById[windowSwitcher.selectedObjectId],
                  stageBounds: switcherStageBounds,
                ),
              const Positioned.fill(child: SystemTrayMenuDismissLayer()),
              DesktopPanelOverlay(
                viewSize: viewSize,
                shellOutputRect: shellOutputRect,
                panelTravel: widget.panelTravel,
                panelDurationScale: widget.panelDurationScale,
                applicationSearchFocusNode: applicationSearchFocusNode,
                onOpenLauncher: onOpenLauncher,
                onDismissLauncher: onDismissLauncher,
                onOpenDashboard: onOpenDashboard,
                onOpenSettings: onOpenSettings,
                onCancelPanelClose: onCancelPanelClose,
                onSchedulePanelClose: onSchedulePanelClose,
                onPanelOpened: widget.onPanelOpened,
                onLaunchApp: onLaunchApp,
                onLaunchLocalApp: onLaunchLocalApp,
              ),
              for (final popup in popupSurfaces)
                if (popup.geometry case final geometry?)
                  RetainedAnimatedPositioned(
                    key: ValueKey<String>(
                      'desktop-popup-surface-${popup.objectId}',
                    ),
                    duration: reduceMotion
                        ? Duration.zero
                        : Motion.inputMethodPopup,
                    curve: Motion.standard,
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
              if (showFrameTimingOverlay)
                const Positioned(
                  top: 12,
                  right: 12,
                  child: ShellFrameTimeOverlay(),
                ),
            ],
          ),
        ),
        surfacePlane(ShellSurfaceLayer.aboveWindows),
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
        const ClipboardTrayLayer(),
        Positioned.fill(
          child: ShellInputRegion(
            debugLabel: 'Wallpaper selector',
            active: wallpaperSelectorVisible,
            pointerPolicy: ShellPointerPolicy.fullScene,
            keyboardPolicy: ShellKeyboardPolicy.capture,
            compositorPolicy: ShellCompositorPolicy.exclusive,
            child: WallpaperSelectorOverlay(
              visible: wallpaperSelectorVisible,
              displayRect: mainDisplayRect,
              onDismiss: onCloseWallpaperSelector,
            ),
          ),
        ),
      ],
    );
  }
}

Rect _unoccupiedDesktopArea(Rect bounds, List<Rect> occupied) {
  var free = <Rect>[bounds];
  for (final obstruction in occupied) {
    final next = <Rect>[];
    for (final area in free) {
      final overlap = area.intersect(obstruction.inflate(14));
      if (overlap.isEmpty) {
        next.add(area);
        continue;
      }
      next.addAll(
        [
          Rect.fromLTRB(area.left, area.top, area.right, overlap.top),
          Rect.fromLTRB(area.left, overlap.bottom, area.right, area.bottom),
          Rect.fromLTRB(area.left, area.top, overlap.left, area.bottom),
          Rect.fromLTRB(overlap.right, area.top, area.right, area.bottom),
        ].where((rect) => !rect.isEmpty),
      );
    }
    free = next;
  }
  if (free.isEmpty) return Rect.zero;
  return free.reduce(
    (a, b) => a.width * a.height >= b.width * b.height ? a : b,
  );
}
