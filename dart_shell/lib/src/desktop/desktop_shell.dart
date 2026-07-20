import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../launcher/controllers/home_grid_controller.dart';
import '../launcher/models/desktop_app.dart';
import '../launcher/models/home_grid_item.dart';
import '../launcher/widgets/home_tiles.dart';
import '../input/shell_interaction_registry.dart';
import '../models/display_layout.dart';
import '../models/denial_window.dart';
import '../platform/denial_bridge.dart';
import '../services/bluetooth_service.dart';
import '../services/desktop_power_modes_service.dart';
import '../services/haptics_service.dart';
import '../services/audio_service.dart';
import '../services/power_profile_service.dart';
import '../state/app_audio.dart';
import '../state/bluetooth.dart';
import '../state/desktop_power_modes.dart';
import '../state/desktop_notifications.dart';
import '../state/desktop_window_close_effect.dart';
import '../state/desktop_window_switcher.dart';
import '../state/display_layout.dart';
import '../state/quick_settings.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/desktop_window_close_animation.dart';
import '../widgets/desktop_window_switcher.dart';
import '../widgets/desktop_window_reveal.dart';
import '../widgets/main_output_centered_surface.dart';
import '../widgets/notification_center.dart';
import '../widgets/session/power_session_surface.dart';
import '../widgets/shell_cursor.dart';
import '../widgets/shell_frame_time_overlay.dart';
import '../widgets/shell_surface_host.dart';
import '../widgets/shell_wallpaper.dart';
import '../widgets/window_surface_tree.dart';
import '../widgets/shade/range_bar.dart';
import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/widgets/wallpaper_selector_surface.dart';
import 'desktop_overview_target.dart';
import 'desktop_system_bar.dart';
import 'desktop_texture_resize.dart';
import 'desktop_window_coordinator.dart';
import 'desktop_window_frame_painter.dart';
import 'desktop_window_render_telemetry.dart';
import 'desktop_workspace.dart';

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  static const Duration _hoverCloseDelay = Duration(milliseconds: 220);

  Timer? _panelCloseTimer;
  Timer? _wallpaperOpenTimer;
  Timer? _windowSwitcherHoldTimer;
  Timer? _windowSwitcherCleanupTimer;
  final FocusNode _applicationSearchFocusNode =
      FocusNode(debugLabel: 'desktop-application-search');
  late final StreamSubscription<DenialShellActionEvent>
      _shellActionSubscription;

  @override
  void initState() {
    super.initState();
    ref.read(hapticsServiceProvider).prewarm();
    _shellActionSubscription =
        ref.read(denialBridgeProvider).shellActions.listen(_handleShellAction);
  }

  @override
  void dispose() {
    _panelCloseTimer?.cancel();
    _wallpaperOpenTimer?.cancel();
    _windowSwitcherHoldTimer?.cancel();
    _windowSwitcherCleanupTimer?.cancel();
    unawaited(_shellActionSubscription.cancel());
    _applicationSearchFocusNode.dispose();
    super.dispose();
  }

  void _handleShellAction(DenialShellActionEvent event) {
    switch (event.action) {
      case DenialShellAction.applications:
        _toggleLauncher();
      case DenialShellAction.overview:
        _cancelWindowSwitcher();
        _toggleOverview(event.monitorId);
      case DenialShellAction.windowSwitcherNext:
        _cycleWindowSwitcher(event.monitorId);
      case DenialShellAction.windowSwitcherEnd:
        _finishWindowSwitcher();
    }
  }

  void _cycleWindowSwitcher(int? preferredMonitorId) {
    _windowSwitcherCleanupTimer?.cancel();
    _windowSwitcherCleanupTimer = null;
    _panelCloseTimer?.cancel();
    _applicationSearchFocusNode.unfocus();

    final shell = ref.read(shellControllerProvider);
    final workspace = ref.read(desktopWorkspaceProvider);
    final windowsById = <int, DenialWindow>{
      for (final window in shell.openAppWindows) window.objectId: window,
    };
    final controller = ref.read(desktopWindowSwitcherProvider.notifier);
    final previous = ref.read(desktopWindowSwitcherProvider);
    if (previous != null && previous.isSelecting) {
      final activeSessionIds = previous.objectIds
          .where(
            (objectId) =>
                windowsById.containsKey(objectId) &&
                workspace.placements.containsKey(objectId),
          )
          .toList(growable: false);
      final next = controller.beginOrAdvance(
        objectIds: activeSessionIds,
        sourceObjectId: previous.sourceObjectId,
      );
      if (next == null) {
        _cancelWindowSwitcher();
        return;
      }
      ref.read(hapticsServiceProvider).pulse();
      return;
    }

    final viewSize = workspace.viewSize.isEmpty
        ? MediaQuery.sizeOf(context)
        : workspace.viewSize;
    final displayLayout = ref.read(displayLayoutProvider);
    final (:systemBarRect, :systemBarSide) =
        _systemBarGeometry(viewSize, displayLayout);
    final monitorTarget = DesktopOverviewTarget.resolve(
      viewSize: viewSize,
      displayLayout: displayLayout,
      windows: shell.openAppWindows,
      workspace: workspace,
      foregroundObjectId: shell.foregroundObjectId,
      preferredMonitorId: preferredMonitorId,
      systemBarRect: systemBarRect,
      systemBarSide: systemBarSide,
    );
    if (monitorTarget == null) {
      return;
    }
    final placements = workspace.placements.values
        .where(
          (placement) =>
              monitorTarget.objectIds.contains(placement.objectId) &&
              windowsById.containsKey(placement.objectId),
        )
        .toList(growable: false)
      ..sort((left, right) => right.z.compareTo(left.z));
    if (placements.length < 2) {
      return;
    }

    final placementIds = placements
        .map((placement) => placement.objectId)
        .toList(growable: true);
    final foregroundId = shell.foregroundObjectId;
    final sourceObjectId =
        foregroundId != null && placementIds.contains(foregroundId)
            ? foregroundId
            : placementIds.first;
    placementIds
      ..remove(sourceObjectId)
      ..insert(0, sourceObjectId);

    if (workspace.overviewActive) {
      ref.read(desktopWorkspaceProvider.notifier).closeOverview();
    }
    ref.read(desktopWorkspaceProvider.notifier).closePanels();

    final next = controller.beginOrAdvance(
      objectIds: placementIds,
      sourceObjectId: sourceObjectId,
    );
    if (next == null) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();

    if (previous?.sessionId == next.sessionId) {
      return;
    }
    _windowSwitcherHoldTimer?.cancel();
    _windowSwitcherHoldTimer = Timer(Motion.windowSwitcherHoldDelay, () {
      if (mounted) {
        controller.expand(next.sessionId);
      }
    });
  }

  void _finishWindowSwitcher() {
    _windowSwitcherHoldTimer?.cancel();
    _windowSwitcherHoldTimer = null;
    final switcher = ref.read(desktopWindowSwitcherProvider);
    if (switcher == null || !switcher.isSelecting) {
      return;
    }

    DenialWindow? target;
    for (final window in ref.read(shellControllerProvider).openAppWindows) {
      if (window.objectId == switcher.selectedObjectId) {
        target = window;
        break;
      }
    }
    if (target == null) {
      _cancelWindowSwitcher();
      return;
    }

    final controller = ref.read(desktopWindowSwitcherProvider.notifier);
    final expanded = switcher.phase == DesktopWindowSwitcherPhase.expanded;
    if (expanded) {
      controller.beginExpandedExit(switcher.sessionId);
    } else {
      controller.beginQuickExit(switcher.sessionId);
    }
    _activateWindow(target);

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final cleanupDelay = reduceMotion
        ? Duration.zero
        : expanded
            ? Motion.windowSwitcherCollapse
            : Motion.windowSwitcherQuick;
    if (cleanupDelay == Duration.zero) {
      controller.clear(switcher.sessionId);
      return;
    }
    _windowSwitcherCleanupTimer?.cancel();
    _windowSwitcherCleanupTimer = Timer(cleanupDelay, () {
      if (mounted) {
        controller.clear(switcher.sessionId);
      }
    });
  }

  void _cancelWindowSwitcher() {
    _windowSwitcherHoldTimer?.cancel();
    _windowSwitcherHoldTimer = null;
    _windowSwitcherCleanupTimer?.cancel();
    _windowSwitcherCleanupTimer = null;
    ref.read(desktopWindowSwitcherProvider.notifier).cancel();
  }

  void _toggleOverview(int? preferredMonitorId) {
    _panelCloseTimer?.cancel();
    _applicationSearchFocusNode.unfocus();

    final workspaceState = ref.read(desktopWorkspaceProvider);
    final workspace = ref.read(desktopWorkspaceProvider.notifier);
    if (workspaceState.overviewActive) {
      workspace.closeOverview();
      return;
    }

    final viewSize = workspaceState.viewSize.isEmpty
        ? MediaQuery.sizeOf(context)
        : workspaceState.viewSize;
    final displayLayout = ref.read(displayLayoutProvider);
    final (:systemBarRect, :systemBarSide) =
        _systemBarGeometry(viewSize, displayLayout);
    final shellState = ref.read(shellControllerProvider);
    final target = DesktopOverviewTarget.resolve(
      viewSize: viewSize,
      displayLayout: displayLayout,
      windows: shellState.openAppWindows,
      workspace: workspaceState,
      foregroundObjectId: shellState.foregroundObjectId,
      preferredMonitorId: preferredMonitorId,
      systemBarRect: systemBarRect,
      systemBarSide: systemBarSide,
    );
    if (target == null) {
      return;
    }

    workspace.closePanels();
    workspace.toggleOverview(
      monitorId: target.monitorId,
      bounds: target.bounds,
      backgroundBounds: target.backgroundBounds,
      objectIds: target.objectIds,
    );
  }

  void _openLauncher() {
    _panelCloseTimer?.cancel();
    ref
        .read(desktopWorkspaceProvider.notifier)
        .showPanel(DesktopPanel.launcher);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _applicationSearchFocusNode.requestFocus();
      }
    });
  }

  void _toggleLauncher() {
    if (ref.read(desktopWorkspaceProvider).launcherOpen) {
      _closePanels();
      return;
    }
    _openLauncher();
  }

  void _closePanels() {
    _panelCloseTimer?.cancel();
    _panelCloseTimer = null;
    ref.read(desktopWorkspaceProvider.notifier).closePanels();
    _applicationSearchFocusNode.unfocus();
  }

  void _openDashboard() {
    _panelCloseTimer?.cancel();
    _applicationSearchFocusNode.unfocus();
    ref
        .read(desktopWorkspaceProvider.notifier)
        .showPanel(DesktopPanel.dashboard);
    unawaited(ref.read(bluetoothProvider.notifier).refresh());
    unawaited(ref.read(desktopPowerModesProvider.notifier).refresh());
  }

  void _openWallpaperSelector() {
    _wallpaperOpenTimer?.cancel();
    _closePanels();
    _wallpaperOpenTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(_showWallpaperSelector());
    });
  }

  void _openAppVolumeManager() {
    _closePanels();
    ref.read(appAudioProvider.notifier).refresh();
    ref.read(shellSurfaceControllerProvider.notifier).show(
          keyName: 'application-volume-manager',
          debugLabel: 'Application volume manager',
          pointerPolicy: ShellPointerPolicy.fullScene,
          keyboardPolicy: ShellKeyboardPolicy.capture,
          dismissPolicy: ShellDismissPolicy.outsideTapAndEscape,
          builder: (_, handle) =>
              _AppVolumeManagerSurface(onDismiss: handle.close),
        );
  }

  Future<void> _showWallpaperSelector() async {
    var displayLayout = ref.read(displayLayoutProvider);
    displayLayout ??=
        await ref.read(displayLayoutProvider.notifier).ensureLoaded();
    if (!mounted) {
      return;
    }
    final logicalSize = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final fallbackPixelSize = logicalSize * pixelRatio;
    final targetPixelSize = displayLayout?.pixelSize ?? fallbackPixelSize;
    ref
        .read(wallpaperControllerProvider.notifier)
        .openSelector(targetPixelSize: targetPixelSize);
  }

  void _closeWallpaperSelector() {
    ref.read(wallpaperControllerProvider.notifier).closeSelector();
  }

  void _cancelPanelClose() {
    _panelCloseTimer?.cancel();
    _panelCloseTimer = null;
  }

  void _schedulePanelClose() {
    _panelCloseTimer?.cancel();
    _panelCloseTimer = Timer(_hoverCloseDelay, () {
      if (mounted) {
        _closePanels();
      }
    });
  }

  Future<void> _launchApp(DesktopApp app) async {
    _closePanels();
    await ref.read(appLauncherProvider).launch(app);
  }

  void _activateWindow(DenialWindow window) {
    ref.read(desktopWorkspaceProvider.notifier).activate(window.objectId);
    ref.read(shellControllerProvider.notifier).focusWindow(window);
  }

  void _handleOverviewBarrierTap(Offset position) {
    final workspace = ref.read(desktopWorkspaceProvider);
    final overview = workspace.overview;
    if (overview == null || overview.backgroundBounds.contains(position)) {
      return;
    }
    final windowsById = <int, DenialWindow>{
      for (final window in ref.read(shellControllerProvider).openAppWindows)
        window.objectId: window,
    };
    final target = desktopWindowAtPosition(
      position: position,
      workspace: workspace,
      windowsById: windowsById,
    );
    ref.read(desktopWorkspaceProvider.notifier).closeOverview();
    if (target != null) {
      _activateWindow(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopWindowCoordinatorProvider);
    ref.listen<int?>(
      shellControllerProvider.select((state) => state.foregroundObjectId),
      (previous, next) {
        if (next != null &&
            next != previous &&
            !ref.read(desktopWorkspaceProvider).overviewActive) {
          ref.read(desktopWorkspaceProvider.notifier).activate(next);
        }
      },
    );
    final windows = ref.watch(
      shellControllerProvider.select((state) => state.openAppWindows),
    );
    final desktop = ref.watch(desktopWorkspaceProvider);
    final closeEffect = ref.watch(desktopWindowCloseEffectProvider);
    final windowSwitcher = ref.watch(desktopWindowSwitcherProvider);
    final nativeDisplayLayout = ref.watch(displayLayoutProvider);
    // DENIA_SHELL_DEV_LAYOUT lets the shell run as an ordinary Wayland client
    // (no native bridge) while still rendering layout-dependent chrome such
    // as the system bar, for styling work without restarting deniald.
    final displayLayout = nativeDisplayLayout ??
        (ref.watch(startupEnvironmentProvider).flag('DENIA_SHELL_DEV_LAYOUT')
            ? DisplayLayout.fallback(
                MediaQuery.sizeOf(context),
                MediaQuery.devicePixelRatioOf(context),
              )
            : null);
    final shellOutput = displayLayout?.systemBarOutput;
    final mainOutput = displayLayout?.mainOutput;
    final wallpaperSelectorVisible = ref.watch(
      wallpaperControllerProvider.select((state) => state.selectorVisible),
    );

    return DefaultTextStyle(
      style: ShellText.base,
      child: ColoredBox(
        color: ShellColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) => _DesktopScene(
            viewSize: constraints.biggest,
            windows: windows,
            desktop: desktop,
            closeEffect: closeEffect,
            windowSwitcher: windowSwitcher,
            displayLayout: displayLayout,
            frameTimingOptions: ref.watch(shellFrameTimingOptionsProvider),
            wallpaperSelectorVisible: wallpaperSelectorVisible,
            shellOutputRect: shellOutput?.logicalRect,
            mainOutputRect: mainOutput?.logicalRect,
            applicationSearchFocusNode: _applicationSearchFocusNode,
            onOpenLauncher: _openLauncher,
            onDismissLauncher: _closePanels,
            onOpenDashboard: _openDashboard,
            onOpenWallpaperSelector: _openWallpaperSelector,
            onCloseWallpaperSelector: _closeWallpaperSelector,
            onOpenAppVolumeManager: _openAppVolumeManager,
            onCancelPanelClose: _cancelPanelClose,
            onSchedulePanelClose: _schedulePanelClose,
            onLaunchApp: _launchApp,
            onActivateWindow: _activateWindow,
            onOverviewBarrierTap: _handleOverviewBarrierTap,
            onCloseLeaseComplete:
                ref.read(denialBridgeProvider).completeWindowClose,
          ),
        ),
      ),
    );
  }
}

/// The clipped system bar strip and its effective side. A bar whose strip
/// cannot land on the visible canvas behaves as hidden everywhere.
({Rect systemBarRect, SystemBarSide systemBarSide}) _systemBarGeometry(
  Size viewSize,
  DisplayLayout? displayLayout,
) {
  final rect = DesktopMetrics.systemBarRect(
    viewSize,
    displayLayout?.systemBarRect ?? Rect.zero,
  );
  return (
    systemBarRect: rect,
    systemBarSide:
        rect.isEmpty ? SystemBarSide.hidden : displayLayout!.systemBarSide,
  );
}

Rect _windowSwitcherStageBounds({
  required Size viewSize,
  required DisplayLayout? displayLayout,
  required DesktopWorkspaceState desktop,
  required DesktopWindowSwitcherState switcher,
}) {
  final canvas = Offset.zero & viewSize;
  final sourcePlacement = desktop.placements[switcher.sourceObjectId];
  if (sourcePlacement == null) {
    return canvas;
  }
  final outputs = displayLayout?.outputs ?? const <DisplayOutput>[];
  for (final output in outputs) {
    if (output.monitorId == sourcePlacement.monitorId) {
      final bounds = output.logicalRect.intersect(canvas);
      if (!bounds.isEmpty) {
        return bounds;
      }
    }
  }
  for (final output in outputs) {
    if (output.logicalRect.contains(sourcePlacement.frame.center)) {
      final bounds = output.logicalRect.intersect(canvas);
      if (!bounds.isEmpty) {
        return bounds;
      }
    }
  }
  return canvas;
}

List<Widget> _buildDesktopWindowLayers({
  required List<DesktopWindowPlacement> placements,
  required Map<int, DenialWindow> windowsById,
  required DesktopWorkspaceState desktop,
  required DesktopWindowSwitcherState? switcher,
  required Rect switcherStageBounds,
  required int topZ,
  required bool reduceMotion,
  required ValueChanged<DenialWindow> onActivateWindow,
}) {
  final layers = <Widget>[];
  for (final placement in placements) {
    final window = windowsById[placement.objectId]!;
    final overview = desktop.isInOverview(placement.objectId);
    final switching = !overview &&
        DesktopWindowSwitcherLayout.contains(switcher, placement.objectId);
    final frame = switching
        ? DesktopWindowSwitcherLayout.visualFrame(
            placement: placement,
            switcher: switcher,
            stageBounds: switcherStageBounds,
          )
        : desktop.visualFrame(placement);
    final visible = overview ||
        (switching
            ? DesktopWindowSwitcherLayout.isVisible(
                placement: placement,
                switcher: switcher,
              )
            : !placement.minimized);
    final motionDuration = reduceMotion
        ? Duration.zero
        : switching
            ? DesktopWindowSwitcherLayout.motionDuration(switcher!)
            : overview
                ? Motion.overviewOpen
                : Motion.overviewClose;
    final active = switching
        ? DesktopWindowSwitcherLayout.isSelected(
            switcher,
            placement.objectId,
          )
        : !overview && !placement.minimized && placement.z == topZ;

    layers
      ..add(
        _DesktopWindowFrame(
          key: ValueKey<int>(placement.objectId),
          window: window,
          placement: placement,
          frame: frame,
          minimized: !visible,
          overview: overview,
          switching: switching,
          motionDuration: motionDuration,
          active: active,
          onOverviewTap: () => onActivateWindow(window),
        ),
      )
      ..add(
        _DesktopPopupSurfaceLayers(
          key: ValueKey<String>(
            'desktop-popup-layers-${placement.objectId}',
          ),
          window: window,
          placement: placement,
          frame: frame,
          minimized: !visible,
          overview: overview,
          switching: switching,
          motionDuration: motionDuration,
        ),
      );
  }
  return layers;
}

class _DesktopScene extends StatefulWidget {
  const _DesktopScene({
    required this.viewSize,
    required this.windows,
    required this.desktop,
    required this.closeEffect,
    required this.windowSwitcher,
    required this.displayLayout,
    required this.frameTimingOptions,
    required this.wallpaperSelectorVisible,
    required this.shellOutputRect,
    required this.mainOutputRect,
    required this.applicationSearchFocusNode,
    required this.onOpenLauncher,
    required this.onDismissLauncher,
    required this.onOpenDashboard,
    required this.onOpenWallpaperSelector,
    required this.onCloseWallpaperSelector,
    required this.onOpenAppVolumeManager,
    required this.onCancelPanelClose,
    required this.onSchedulePanelClose,
    required this.onLaunchApp,
    required this.onActivateWindow,
    required this.onOverviewBarrierTap,
    required this.onCloseLeaseComplete,
  });

  final Size viewSize;
  final List<DenialWindow> windows;
  final DesktopWorkspaceState desktop;
  final DesktopWindowCloseEffect closeEffect;
  final DesktopWindowSwitcherState? windowSwitcher;
  final DisplayLayout? displayLayout;
  final ShellFrameTimingOptions frameTimingOptions;
  final bool wallpaperSelectorVisible;
  final Rect? shellOutputRect;
  final Rect? mainOutputRect;
  final FocusNode applicationSearchFocusNode;
  final VoidCallback onOpenLauncher;
  final VoidCallback onDismissLauncher;
  final VoidCallback onOpenDashboard;
  final VoidCallback onOpenWallpaperSelector;
  final VoidCallback onCloseWallpaperSelector;
  final VoidCallback onOpenAppVolumeManager;
  final VoidCallback onCancelPanelClose;
  final VoidCallback onSchedulePanelClose;
  final ValueChanged<DesktopApp> onLaunchApp;
  final ValueChanged<DenialWindow> onActivateWindow;
  final ValueChanged<Offset> onOverviewBarrierTap;
  final ValueChanged<int> onCloseLeaseComplete;

  @override
  State<_DesktopScene> createState() => _DesktopSceneState();
}

class _DesktopSceneState extends State<_DesktopScene> {
  final Map<int, _ClosingDesktopWindow> _closingWindows =
      <int, _ClosingDesktopWindow>{};
  int _nextCloseId = 1;

  @override
  void didUpdateWidget(covariant _DesktopScene oldWidget) {
    super.didUpdateWidget(oldWidget);

    final activeObjectIds = <int>{
      for (final window in widget.windows) window.objectId,
    };
    for (final window in oldWidget.windows) {
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
      _closingWindows[closeId] = _ClosingDesktopWindow(
        id: closeId,
        window: window,
        frame: frame,
        fullscreen: placement.fullscreen &&
            !oldWidget.desktop.isInOverview(window.objectId),
        effect: widget.closeEffect,
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

  @override
  void dispose() {
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
    final desktop = widget.desktop;
    final windowSwitcher = widget.windowSwitcher;
    final displayLayout = widget.displayLayout;
    final frameTimingOptions = widget.frameTimingOptions;
    final wallpaperSelectorVisible = widget.wallpaperSelectorVisible;
    final shellOutputRect = widget.shellOutputRect;
    final mainOutputRect = widget.mainOutputRect;
    final applicationSearchFocusNode = widget.applicationSearchFocusNode;
    final onOpenLauncher = widget.onOpenLauncher;
    final onDismissLauncher = widget.onDismissLauncher;
    final onOpenDashboard = widget.onOpenDashboard;
    final onOpenWallpaperSelector = widget.onOpenWallpaperSelector;
    final onCloseWallpaperSelector = widget.onCloseWallpaperSelector;
    final onOpenAppVolumeManager = widget.onOpenAppVolumeManager;
    final onCancelPanelClose = widget.onCancelPanelClose;
    final onSchedulePanelClose = widget.onSchedulePanelClose;
    final onLaunchApp = widget.onLaunchApp;
    final onActivateWindow = widget.onActivateWindow;
    final onOverviewBarrierTap = widget.onOverviewBarrierTap;
    final windowsById = <int, DenialWindow>{
      for (final window in windows) window.objectId: window,
    };
    final placements = desktop.placements.values
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
    final topZ = placements
        .where((placement) => !placement.minimized)
        .fold<int>(0, (value, placement) => math.max(value, placement.z));
    final (:systemBarRect, :systemBarSide) =
        _systemBarGeometry(viewSize, displayLayout);
    final launcherRect = DesktopMetrics.launcherRect(
      viewSize,
      outputRect: shellOutputRect,
    );
    final dashboardRect = DesktopMetrics.dashboardRect(
      viewSize,
      outputRect: shellOutputRect,
    );
    final launcherTriggerRect = DesktopMetrics.launcherTriggerRect(
      viewSize,
      outputRect: shellOutputRect,
    );
    final dashboardTriggerRect = DesktopMetrics.dashboardTriggerRect(
      viewSize,
      outputRect: shellOutputRect,
    );
    // True fullscreen owns the complete output, so the bar yields instead of
    // floating above the fullscreen surface.
    final systemBarMonitorId = displayLayout?.systemBarOutput?.monitorId;
    final fullscreenCoversSystemBar = !desktop.overviewActive &&
        placements.any(
          (placement) =>
              placement.fullscreen &&
              !placement.minimized &&
              placement.monitorId == systemBarMonitorId,
        );
    final systemBarVisible =
        !systemBarRect.isEmpty && !fullscreenCoversSystemBar;
    final canvas = Offset.zero & viewSize;
    final requestedDisplayRect = mainOutputRect?.intersect(canvas);
    final mainDisplayRect =
        requestedDisplayRect == null || requestedDisplayRect.isEmpty
            ? canvas
            : requestedDisplayRect;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final selectorMotionDuration =
        reduceMotion ? Duration.zero : Motion.wallpaperSelector;
    final switcherStageBounds = windowSwitcher == null
        ? Rect.zero
        : _windowSwitcherStageBounds(
            viewSize: viewSize,
            displayLayout: displayLayout,
            desktop: desktop,
            switcher: windowSwitcher,
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        const ShellWallpaper(),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: wallpaperSelectorVisible,
            child: AnimatedOpacity(
              duration: selectorMotionDuration,
              curve: Motion.md3EmphasizedAccelerate,
              opacity: wallpaperSelectorVisible ? 0.0 : 1.0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const _DesktopWidgetCanvas(),
                  // The bar belongs to the wallpaper plane. Any window moved
                  // into its reserved strip paints and receives input above it.
                  if (systemBarVisible)
                    Positioned.fromRect(
                      rect: systemBarRect,
                      child: IgnorePointer(
                        child: DesktopSystemBar(side: systemBarSide),
                      ),
                    ),
                  Positioned.fill(
                    child: ShellInputRegion(
                      debugLabel: 'Desktop overview',
                      active: desktop.overviewActive,
                      pointerPolicy: ShellPointerPolicy.fullScene,
                      keyboardPolicy: ShellKeyboardPolicy.capture,
                      compositorPolicy: ShellCompositorPolicy.exclusive,
                      child: const IgnorePointer(child: SizedBox.expand()),
                    ),
                  ),
                  Positioned.fill(
                    child: _DesktopOverviewBarrier(
                      active: desktop.overviewActive,
                      onTap: onOverviewBarrierTap,
                    ),
                  ),
                  if (windowSwitcher != null)
                    DesktopWindowSwitcherBackdrop(
                      switcher: windowSwitcher,
                      bounds: switcherStageBounds,
                    ),
                  ..._buildDesktopWindowLayers(
                    placements: placements,
                    windowsById: windowsById,
                    desktop: desktop,
                    switcher: windowSwitcher,
                    switcherStageBounds: switcherStageBounds,
                    topZ: topZ,
                    reduceMotion: reduceMotion,
                    onActivateWindow: onActivateWindow,
                  ),
                  for (final closing in _closingWindows.values)
                    Positioned.fromRect(
                      key: ValueKey<String>(
                        'desktop-closing-window-${closing.id}',
                      ),
                      rect: closing.frame,
                      child: _DesktopClosingWindowFrame(
                        closing: closing,
                        onCompleted: () => _completeCloseAnimation(closing.id),
                      ),
                    ),
                  if (windowSwitcher != null)
                    DesktopWindowSwitcherLayer(
                      key: ValueKey<String>(
                        'desktop-window-switcher-${windowSwitcher.sessionId}',
                      ),
                      switcher: windowSwitcher,
                      selectedWindow:
                          windowsById[windowSwitcher.selectedObjectId],
                      stageBounds: switcherStageBounds,
                    ),
                  if (desktop.launcherOpen)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onDismissLauncher,
                      ),
                    ),
                  if (!launcherRect.isEmpty)
                    Positioned.fromRect(
                      rect: launcherRect,
                      child: _DesktopPanelTransition(
                        key: const ValueKey<String>('desktop-launcher-panel'),
                        inputDebugLabel: 'Desktop application launcher',
                        keyboardPolicy: ShellKeyboardPolicy.capture,
                        visible: desktop.launcherOpen,
                        child: _DesktopAppLauncher(
                          searchFocusNode: applicationSearchFocusNode,
                          onEnter: onCancelPanelClose,
                          onExit: onSchedulePanelClose,
                          onLaunch: onLaunchApp,
                        ),
                      ),
                    ),
                  if (!dashboardRect.isEmpty)
                    Positioned.fromRect(
                      rect: dashboardRect,
                      child: _DesktopPanelTransition(
                        key: const ValueKey<String>('desktop-dashboard-panel'),
                        inputDebugLabel: 'Desktop dashboard',
                        keyboardPolicy: ShellKeyboardPolicy.capture,
                        visible: desktop.dashboardOpen,
                        child: _DesktopDashboard(
                          onEnter: onCancelPanelClose,
                          onExit: onSchedulePanelClose,
                          onOpenWallpaper: onOpenWallpaperSelector,
                          onOpenAppVolumeManager: onOpenAppVolumeManager,
                        ),
                      ),
                    ),
                  if (!desktop.overviewActive && !launcherTriggerRect.isEmpty)
                    Positioned.fromRect(
                      rect: launcherTriggerRect,
                      child: ShellInputRegion(
                        debugLabel: 'Desktop launcher edge trigger',
                        child: _DesktopPanelEdgeTrigger(
                          onEnter: onOpenLauncher,
                          onExit: onSchedulePanelClose,
                        ),
                      ),
                    ),
                  if (!desktop.overviewActive && !dashboardTriggerRect.isEmpty)
                    Positioned.fromRect(
                      rect: dashboardTriggerRect,
                      child: ShellInputRegion(
                        debugLabel: 'Desktop dashboard edge trigger',
                        child: _DesktopPanelEdgeTrigger(
                          onEnter: onOpenDashboard,
                          onExit: onSchedulePanelClose,
                        ),
                      ),
                    ),
                  if (frameTimingOptions.showOverlay)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: ShellFrameTimingOverlayStack(
                        windows: windows,
                        showImportedTextureCharts:
                            frameTimingOptions.showImportedTextureCharts,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
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

class _AppVolumeManagerSurface extends ConsumerWidget {
  const _AppVolumeManagerSurface({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(appAudioProvider);
    final controller = ref.read(appAudioProvider.notifier);
    return MainOutputCenteredSurface(
      builder: (context, constraints) {
        final panelWidth = math.min(560.0, constraints.maxWidth);
        final panelHeight = math.min(520.0, constraints.maxHeight);
        return SizedBox(
          width: panelWidth,
          height: panelHeight,
          child: _AppVolumeManagerPanel(
            state: audio,
            onRefresh: controller.refresh,
            onDismiss: onDismiss,
            onChanged: controller.setVolume,
            onChangeEnd: controller.commitVolume,
          ),
        );
      },
    );
  }
}

class _AppVolumeManagerPanel extends StatelessWidget {
  const _AppVolumeManagerPanel({
    required this.state,
    required this.onRefresh,
    required this.onDismiss,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppAudioState state;
  final VoidCallback onRefresh;
  final VoidCallback onDismiss;
  final void Function(int streamId, double value) onChanged;
  final void Function(int streamId, double value) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.panelBackground,
          borderRadius: BorderRadius.circular(ShellRadii.panel),
          border: Border.all(color: ShellColors.hairline),
          boxShadow: const [
            BoxShadow(
              color: ShellColors.shadow,
              blurRadius: 42,
              spreadRadius: 4,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ShellRadii.panel),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 18, 16),
                child: Row(
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        color: ShellColors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: 42,
                        height: 42,
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          size: 23,
                          color: ShellColors.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Application volume',
                            style: ShellText.statusClock.copyWith(fontSize: 20),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            'Applications currently emitting audio',
                            style: ShellText.cardTitle.copyWith(
                              color: ShellColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _DashboardIconButton(
                      semanticLabel: 'Refresh application audio streams',
                      icon: Icons.refresh_rounded,
                      busy: state.loading,
                      onTap: onRefresh,
                    ),
                    const SizedBox(width: 8),
                    _DashboardIconButton(
                      semanticLabel: 'Close application volume manager',
                      icon: Icons.close_rounded,
                      onTap: onDismiss,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: ShellColors.hairlineSoft),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (state.loading && state.streams.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: ShellColors.accent,
          ),
        ),
      );
    }
    if (state.error != null && state.streams.isEmpty) {
      return _AppVolumeManagerMessage(
        icon: Icons.cloud_off_rounded,
        message: state.error!,
        actionLabel: 'Retry',
        onAction: onRefresh,
      );
    }
    if (state.streams.isEmpty) {
      return const _AppVolumeManagerMessage(
        icon: Icons.music_off_rounded,
        message: 'No applications are currently playing audio.',
      );
    }

    return Scrollbar(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
        itemCount: state.streams.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final stream = state.streams[index];
          return _AppVolumeRow(
            key: ValueKey<int>(stream.id),
            stream: stream,
            onChanged: (value) => onChanged(stream.id, value),
            onChangeEnd: (value) => onChangeEnd(stream.id, value),
          );
        },
      ),
    );
  }
}

class _AppVolumeManagerMessage extends StatelessWidget {
  const _AppVolumeManagerMessage({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: ShellColors.textTertiary),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: ShellText.cardTitle.copyWith(
                color: ShellColors.textSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              _DashboardValueButton(
                semanticLabel: actionLabel!,
                label: actionLabel!,
                icon: Icons.refresh_rounded,
                onTap: onAction!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AppVolumeRow extends StatefulWidget {
  const _AppVolumeRow({
    super.key,
    required this.stream,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppAudioStream stream;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_AppVolumeRow> createState() => _AppVolumeRowState();
}

class _AppVolumeRowState extends State<_AppVolumeRow> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'app-volume-slider');
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _adjust(double delta) {
    widget.onChangeEnd(
      (widget.stream.level + delta).clamp(0.0, 1.0).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final percent = (widget.stream.level * 100).round();
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _adjust(-0.05);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _adjust(0.05);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        slider: true,
        label: 'Volume for ${widget.stream.name}',
        value: '$percent%',
        increasedValue: '${math.min(100, percent + 5)}%',
        decreasedValue: '${math.max(0, percent - 5)}%',
        onIncrease: () => _adjust(0.05),
        onDecrease: () => _adjust(-0.05),
        child: Listener(
          onPointerDown: (_) => _focusNode.requestFocus(),
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: _focused
                  ? ShellColors.surfaceContainerHigh
                  : ShellColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: _focused ? ShellColors.accent : ShellColors.hairlineSoft,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        color: ShellColors.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: Icon(
                          widget.stream.muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          size: 19,
                          color: widget.stream.muted
                              ? ShellColors.textTertiary
                              : ShellColors.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        widget.stream.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.cardTitle.copyWith(fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$percent%',
                      style: ShellText.cardTitle.copyWith(
                        color: ShellColors.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                RangeBar(
                  icon: widget.stream.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  value: widget.stream.level,
                  activeColor: ShellColors.accent,
                  inactiveColor: ShellColors.volumeTrack,
                  onChanged: widget.onChanged,
                  onChangeEnd: widget.onChangeEnd,
                  height: 40,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopPanelTransition extends StatefulWidget {
  const _DesktopPanelTransition({
    super.key,
    required this.inputDebugLabel,
    required this.visible,
    required this.child,
    this.keyboardPolicy = ShellKeyboardPolicy.none,
  });

  final String inputDebugLabel;
  final bool visible;
  final Widget child;
  final ShellKeyboardPolicy keyboardPolicy;

  @override
  State<_DesktopPanelTransition> createState() =>
      _DesktopPanelTransitionState();
}

class _DesktopPanelTransitionState extends State<_DesktopPanelTransition>
    with SingleTickerProviderStateMixin {
  static const double _slideDistance = 32.0;

  late final AnimationController _controller;
  late final Animation<double> _progress;
  late bool _showChild;

  @override
  void initState() {
    super.initState();
    _showChild = widget.visible;
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1.0 : 0.0,
      duration: Motion.desktopPanelOpen,
      reverseDuration: Motion.desktopPanelClose,
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Motion.md3EmphasizedDecelerate,
      reverseCurve: Motion.md3EmphasizedAccelerate,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _controller
      ..duration = reduceMotion ? Duration.zero : Motion.desktopPanelOpen
      ..reverseDuration =
          reduceMotion ? Duration.zero : Motion.desktopPanelClose;
  }

  @override
  void didUpdateWidget(covariant _DesktopPanelTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) {
      return;
    }

    if (widget.visible) {
      _showChild = true;
      _controller.forward();
      return;
    }

    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted || widget.visible || _controller.value != 0.0) {
        return;
      }
      setState(() => _showChild = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showChild) {
      return const SizedBox.shrink();
    }

    return ShellInputRegion(
      debugLabel: widget.inputDebugLabel,
      keyboardPolicy:
          widget.visible ? widget.keyboardPolicy : ShellKeyboardPolicy.none,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ExcludeSemantics(
          excluding: !widget.visible,
          child: AnimatedBuilder(
            animation: _progress,
            child: RepaintBoundary(child: widget.child),
            builder: (context, child) {
              final progress = _progress.value;
              return Opacity(
                opacity: progress,
                child: Transform.translate(
                  offset: Offset(-_slideDistance * (1.0 - progress), 0.0),
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DesktopPanelEdgeTrigger extends StatelessWidget {
  const _DesktopPanelEdgeTrigger({
    required this.onEnter,
    required this.onExit,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: MouseRegion(
        opaque: true,
        onEnter: (_) => onEnter(),
        onExit: (_) => onExit(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _DesktopOverviewBarrier extends StatelessWidget {
  const _DesktopOverviewBarrier({
    required this.active,
    required this.onTap,
  });

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

class _DesktopWidgetCanvas extends ConsumerWidget {
  const _DesktopWidgetCanvas();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batterySeries = ref.watch(homeBatteryDischargeProvider).asData?.value;
    final hasBatteryData = batterySeries?.points.any(
          (point) =>
              point.capacity != null ||
              point.currentMa != null ||
              point.voltageMv != null ||
              point.powerMw != null,
        ) ??
        false;
    final widgets = ref
            .watch(homeGridControllerProvider)
            .asData
            ?.value
            .slots
            .whereType<HomeGridItem>()
            .where(
              (item) =>
                  item.type != HomeGridItemType.app &&
                  (item.type != HomeGridItemType.batteryDischarge ||
                      hasBatteryData),
            )
            .toList(growable: false) ??
        const <HomeGridItem>[];
    if (widgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 96),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 420),
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              childAspectRatio: 1.75,
            ),
            itemCount: widgets.length,
            itemBuilder: (context, index) =>
                _DesktopHomeWidget(item: widgets[index]),
          ),
        ),
      ),
    );
  }
}

class _DesktopHomeWidget extends StatelessWidget {
  const _DesktopHomeWidget({required this.item});

  final HomeGridItem item;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: HomeGridItemCard(
        item: item,
        launchEnabled: false,
        onLaunch: (_) {},
      ),
    );
    return RepaintBoundary(
      child: item.type == HomeGridItemType.clock
          ? content
          : DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.panelBackground,
                borderRadius: BorderRadius.circular(ShellRadii.tile),
                border: Border.all(color: ShellColors.hairlineSoft),
              ),
              child: content,
            ),
    );
  }
}

class _DesktopPopupSurfaceLayers extends StatelessWidget {
  const _DesktopPopupSurfaceLayers({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.overview,
    required this.switching,
    required this.motionDuration,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
  final bool overview;
  final bool switching;
  final Duration motionDuration;

  @override
  Widget build(BuildContext context) {
    if (window.surfaceLayers.isEmpty) {
      return const SizedBox.shrink();
    }

    final transformed = overview || switching;
    final fullscreenVisual = placement.fullscreen && !transformed;
    final drawsServerFrame = !fullscreenVisual && placement.serverSideDecorated;
    final contentRect =
        drawsServerFrame ? frame.deflate(DesktopMetrics.frameBorder) : frame;
    final duration =
        placement.dragging && !transformed ? Duration.zero : motionDuration;
    final resizing = desktopTextureNeedsResizeSmoothing(
      targetSize: contentRect.size,
      sourceSize: window.contentCoordinateRect.size,
    );
    final filterQuality =
        transformed || resizing ? FilterQuality.high : FilterQuality.none;

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: duration,
          curve: Motion.md3EmphasizedAccelerate,
          opacity: minimized ? 0.0 : 1.0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final layer in window.popupSurfaceLayers)
                if (layer.textureId > 0)
                  AnimatedPositioned.fromRect(
                    key: ValueKey<int>(layer.surfaceId),
                    duration: duration,
                    curve: Motion.md3Emphasized,
                    rect: window.mapSurfaceRect(layer, contentRect),
                    child: SurfaceLayerTexture(
                      layer: layer,
                      filterQuality: filterQuality,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClosingDesktopWindow {
  const _ClosingDesktopWindow({
    required this.id,
    required this.window,
    required this.frame,
    required this.fullscreen,
    required this.effect,
  });

  final int id;
  final DenialWindow window;
  final Rect frame;
  final bool fullscreen;
  final DesktopWindowCloseEffect effect;
}

class _DesktopClosingWindowFrame extends StatelessWidget {
  const _DesktopClosingWindowFrame({
    required this.closing,
    required this.onCompleted,
  });

  final _ClosingDesktopWindow closing;
  final VoidCallback onCompleted;

  @override
  Widget build(BuildContext context) {
    final drawsServerFrame =
        !closing.fullscreen && closing.window.serverSideDecorated;
    final radius = drawsServerFrame ? ShellRadii.window : 0.0;
    return DesktopWindowCloseAnimation(
      effect: closing.effect,
      seed: Object.hash(closing.window.objectId, closing.id),
      onCompleted: onCompleted,
      child: CustomPaint(
        painter: drawsServerFrame
            ? DesktopWindowFramePainter(
                windowId: closing.window.objectId,
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(math.max(0.0, radius - 1.0)),
          child: Padding(
            padding: drawsServerFrame
                ? const EdgeInsets.all(DesktopMetrics.frameBorder)
                : EdgeInsets.zero,
            child: SizedBox.expand(
              child: _DesktopSurfaceTexture(
                window: closing.window,
                smooth: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopWindowFrame extends StatelessWidget {
  const _DesktopWindowFrame({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.overview,
    required this.switching,
    required this.motionDuration,
    required this.active,
    required this.onOverviewTap,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
  final bool overview;
  final bool switching;
  final Duration motionDuration;
  final bool active;
  final VoidCallback onOverviewTap;

  @override
  Widget build(BuildContext context) {
    DesktopWindowRenderTelemetry.recordWindowBuild(
      windowId: window.objectId,
      textureId: window.textureId,
      label: window.appId.isEmpty ? window.displayTitle : window.appId,
    );
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final transformed = overview || switching;
    final duration = motionDuration;
    final fullscreenVisual = placement.fullscreen && !transformed;
    final drawsServerFrame = !fullscreenVisual && placement.serverSideDecorated;
    final windowRadius = drawsServerFrame ? ShellRadii.window : 0.0;
    final targetContentSize = drawsServerFrame
        ? frame.deflate(DesktopMetrics.frameBorder).size
        : frame.size;
    final resizing = desktopTextureNeedsResizeSmoothing(
      targetSize: targetContentSize,
      sourceSize: window.contentCoordinateRect.size,
    );
    return AnimatedPositioned(
      duration: placement.dragging && !transformed ? Duration.zero : duration,
      curve: Motion.md3Emphasized,
      left: frame.left,
      top: frame.top,
      width: frame.width,
      height: frame.height,
      child: DesktopWindowReveal(
        key: ValueKey<String>('desktop-window-content-${window.objectId}'),
        enabled: !window.suppressAnimations,
        child: IgnorePointer(
          ignoring: minimized,
          child: AnimatedSlide(
            duration: duration,
            curve: Motion.md3EmphasizedAccelerate,
            offset: minimized ? const Offset(0, 0.16) : Offset.zero,
            child: AnimatedScale(
              duration: duration,
              curve: Motion.md3EmphasizedAccelerate,
              scale: minimized ? 0.84 : 1.0,
              child: AnimatedOpacity(
                duration: duration,
                curve: Motion.md3EmphasizedAccelerate,
                opacity: minimized ? 0.0 : 1.0,
                child: RepaintBoundary(
                  child: Semantics(
                    button: overview,
                    label: overview ? 'Activate ${window.displayTitle}' : null,
                    child: MouseRegion(
                      cursor: overview
                          ? ShellMouseCursors.link
                          : ShellMouseCursors.normal,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: overview ? onOverviewTap : null,
                        child: Builder(
                          builder: (context) {
                            final client = ClipRRect(
                              borderRadius: BorderRadius.circular(
                                math.max(0.0, windowRadius - 1.0),
                              ),
                              child: Padding(
                                // The native client keeps its real geometry
                                // during overview; only its live texture scales.
                                padding: drawsServerFrame
                                    ? const EdgeInsets.all(
                                        DesktopMetrics.frameBorder,
                                      )
                                    : EdgeInsets.zero,
                                child: SizedBox.expand(
                                  child: _DesktopSurfaceTexture(
                                    window: window,
                                    smooth: transformed || resizing,
                                  ),
                                ),
                              ),
                            );
                            if (!drawsServerFrame) {
                              return client;
                            }
                            return DesktopWindowFrameLayers(
                              windowId: window.objectId,
                              borderPainter: _DesktopWindowBorderPainter(
                                windowId: window.objectId,
                                color: window.pinned
                                    ? ShellColors.pinnedWindowBorder
                                    : active
                                        ? ShellColors.focusedWindowBorder
                                        : ShellColors.hairlineWindow,
                                devicePixelRatio: devicePixelRatio,
                              ),
                              child: client,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSurfaceTexture extends StatefulWidget {
  const _DesktopSurfaceTexture({
    required this.window,
    required this.smooth,
  });

  final DenialWindow window;
  final bool smooth;

  @override
  State<_DesktopSurfaceTexture> createState() => _DesktopSurfaceTextureState();
}

class _DesktopSurfaceTextureState extends State<_DesktopSurfaceTexture> {
  Timer? _disableSmoothingTimer;
  late bool _smooth;

  @override
  void initState() {
    super.initState();
    _smooth = widget.smooth;
  }

  @override
  void didUpdateWidget(covariant _DesktopSurfaceTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.smooth) {
      _disableSmoothingTimer?.cancel();
      _disableSmoothingTimer = null;
      _smooth = true;
    } else if (oldWidget.smooth && _smooth) {
      _disableSmoothingTimer?.cancel();
      _disableSmoothingTimer = Timer(Motion.overviewClose, () {
        if (mounted) {
          setState(() => _smooth = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _disableSmoothingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filterQuality = _smooth ? FilterQuality.high : FilterQuality.none;
    return WindowSurfaceTree(
      window: widget.window,
      filterQuality: filterQuality,
    );
  }
}

class _DesktopWindowBorderPainter extends CustomPainter {
  const _DesktopWindowBorderPainter({
    required this.windowId,
    required this.color,
    required this.devicePixelRatio,
  });

  final int windowId;
  final Color color;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    DesktopWindowRenderTelemetry.recordBorderPaint(windowId, size);
    if (size.isEmpty) {
      return;
    }

    final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0.0
        ? devicePixelRatio
        : 1.0;
    final pixel = 1.0 / ratio;
    final inset = pixel / 2.0;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      math.max(0.0, size.width - pixel),
      math.max(0.0, size.height - pixel),
    );
    final radius = math.max(0.0, ShellRadii.window - inset);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = pixel
      ..isAntiAlias = false;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _DesktopWindowBorderPainter oldDelegate) {
    return windowId != oldDelegate.windowId ||
        color != oldDelegate.color ||
        devicePixelRatio != oldDelegate.devicePixelRatio;
  }
}

class _DesktopDashboard extends ConsumerWidget {
  const _DesktopDashboard({
    required this.onEnter,
    required this.onExit,
    required this.onOpenWallpaper,
    required this.onOpenAppVolumeManager,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onOpenWallpaper;
  final VoidCallback onOpenAppVolumeManager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quickSettings = ref.watch(quickSettingsProvider);
    final quickSettingsController = ref.read(quickSettingsProvider.notifier);
    final bluetooth = ref.watch(bluetoothProvider);
    final bluetoothController = ref.read(bluetoothProvider.notifier);
    final notifications = ref.watch(desktopNotificationsProvider);

    void openNotifications() {
      ref.read(shellSurfaceControllerProvider.notifier).show(
            keyName: 'desktop-notification-center',
            debugLabel: 'Notification center',
            builder: (context, handle) =>
                _DesktopNotificationCenterDialog(handle: handle),
          );
    }

    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: FocusTraversalGroup(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.panelBackground,
            borderRadius: BorderRadius.circular(ShellRadii.panel),
            border: Border.all(color: ShellColors.hairline),
            boxShadow: const [
              BoxShadow(
                color: ShellColors.shadow,
                blurRadius: 36,
                spreadRadius: 3,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Dashboard',
                        style: ShellText.statusClock.copyWith(fontSize: 22),
                      ),
                    ),
                    _DashboardIconButton(
                      semanticLabel: notifications.unreadCount == 0
                          ? 'Open notification center'
                          : 'Open notification center, '
                              '${notifications.unreadCount} unread',
                      icon: notifications.unreadCount == 0
                          ? Icons.notifications_none_rounded
                          : Icons.notifications_active_rounded,
                      active: notifications.unreadCount > 0,
                      onTap: openNotifications,
                    ),
                    const SizedBox(width: 7),
                    _DashboardIconButton(
                      semanticLabel: 'Open power and session controls',
                      icon: Icons.power_settings_new_rounded,
                      onTap: () => showPowerSessionSurface(ref),
                    ),
                    const SizedBox(width: 7),
                    _DashboardIconButton(
                      semanticLabel: 'Choose wallpaper',
                      icon: Icons.wallpaper_rounded,
                      onTap: onOpenWallpaper,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _DashboardCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.volume_up_rounded,
                            size: 21,
                            color: ShellColors.accent,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text('Volume', style: ShellText.cardTitle),
                          ),
                          _DashboardValueButton(
                            semanticLabel: 'Open application volume manager',
                            label: '${(quickSettings.volume * 100).round()}%',
                            icon: Icons.tune_rounded,
                            onTap: onOpenAppVolumeManager,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      RangeBar(
                        icon: quickSettings.volume <= 0.01
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        value: quickSettings.volume,
                        activeColor: ShellColors.accent,
                        inactiveColor: ShellColors.volumeTrack,
                        onChangeStart:
                            quickSettingsController.beginVolumeInteraction,
                        onChanged: quickSettingsController.setVolume,
                        onChangeEnd: quickSettingsController.commitVolume,
                        height: 48,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const _DesktopPowerModesCard(),
                const SizedBox(height: 12),
                const _DesktopWindowCloseEffectCard(),
                const SizedBox(height: 12),
                Expanded(
                  child: _DashboardCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.bluetooth_rounded,
                              size: 21,
                              color: ShellColors.accent,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child:
                                  Text('Bluetooth', style: ShellText.cardTitle),
                            ),
                            _DashboardIconButton(
                              semanticLabel: bluetooth.powered
                                  ? 'Disattiva Bluetooth'
                                  : 'Attiva Bluetooth',
                              icon: Icons.power_settings_new_rounded,
                              active: bluetooth.powered,
                              busy: bluetooth.powerChanging,
                              onTap: bluetoothController.togglePower,
                            ),
                            const SizedBox(width: 7),
                            _DashboardIconButton(
                              semanticLabel: 'Cerca dispositivi Bluetooth',
                              icon: Icons.bluetooth_searching_rounded,
                              active:
                                  bluetooth.scanning || bluetooth.discovering,
                              busy: bluetooth.scanning,
                              enabled: bluetooth.powered,
                              onTap: bluetoothController.scan,
                            ),
                            const SizedBox(width: 7),
                            _DashboardIconButton(
                              semanticLabel: 'Aggiorna dispositivi Bluetooth',
                              icon: Icons.refresh_rounded,
                              busy: bluetooth.refreshing,
                              onTap: bluetoothController.refresh,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (bluetooth.error case final error?) ...[
                          Text(
                            error,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ShellText.cardTitle.copyWith(
                              color: ShellColors.performanceBad,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        Expanded(
                          child: _BluetoothDeviceList(
                            state: bluetooth,
                            onToggleConnection:
                                bluetoothController.toggleConnection,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopNotificationCenterDialog extends StatelessWidget {
  const _DesktopNotificationCenterDialog({required this.handle});

  final ShellSurfaceHandle handle;

  @override
  Widget build(BuildContext context) {
    return MainOutputCenteredSurface(
      builder: (context, constraints) {
        final panelWidth = math.min(520.0, constraints.maxWidth);
        final panelHeight = math.min(720.0, constraints.maxHeight);
        return SizedBox(
          width: panelWidth,
          height: panelHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ShellColors.panelBackground,
              borderRadius: BorderRadius.circular(ShellRadii.panel),
              border: Border.all(color: ShellColors.hairline),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: ShellColors.shadow,
                  blurRadius: 36,
                  spreadRadius: 3,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Notifications',
                          style: ShellText.statusClock.copyWith(fontSize: 22),
                        ),
                      ),
                      _DashboardIconButton(
                        semanticLabel: 'Close notification center',
                        icon: Icons.close_rounded,
                        onTap: handle.close,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Expanded(
                    child: NotificationCenter(showTitle: false),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ShellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

class _DesktopWindowCloseEffectCard extends ConsumerWidget {
  const _DesktopWindowCloseEffectCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(desktopWindowCloseEffectProvider);
    final controller = ref.read(desktopWindowCloseEffectProvider.notifier);
    return _DashboardCard(
      child: Row(
        children: [
          const Icon(
            Icons.animation_rounded,
            size: 21,
            color: ShellColors.accent,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Chiusura finestre',
              style: ShellText.cardTitle,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: ShellColors.surfaceContainer,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: ShellColors.hairlineSoft),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PowerModeOption(
                    semanticLabel: 'Animazione di chiusura Esplosione',
                    icon: Icons.blur_on_rounded,
                    selected: selected == DesktopWindowCloseEffect.explosion,
                    busy: false,
                    enabled: true,
                    onTap: () => controller.select(
                      DesktopWindowCloseEffect.explosion,
                    ),
                  ),
                  _PowerModeOption(
                    semanticLabel: 'Animazione di chiusura Risucchio',
                    icon: Icons.compress_rounded,
                    selected: selected == DesktopWindowCloseEffect.implode,
                    busy: false,
                    enabled: true,
                    onTap: () => controller.select(
                      DesktopWindowCloseEffect.implode,
                    ),
                  ),
                  _PowerModeOption(
                    semanticLabel: 'Animazione di chiusura Sfuma',
                    icon: Icons.blur_off_rounded,
                    selected: selected == DesktopWindowCloseEffect.fade,
                    busy: false,
                    enabled: true,
                    onTap: () => controller.select(
                      DesktopWindowCloseEffect.fade,
                    ),
                  ),
                  _PowerModeOption(
                    semanticLabel: 'Disattiva animazione di chiusura',
                    icon: Icons.motion_photos_off_rounded,
                    selected: selected == DesktopWindowCloseEffect.none,
                    busy: false,
                    enabled: true,
                    onTap: () => controller.select(
                      DesktopWindowCloseEffect.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopPowerModesCard extends ConsumerWidget {
  const _DesktopPowerModesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = ref.watch(desktopPowerModesProvider);
    final controller = ref.read(desktopPowerModesProvider.notifier);
    final systemEnabled = modes.systemAvailable && !modes.systemChanging;
    final pboEnabled = modes.pboAvailable && !modes.pboChanging;

    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.tune_rounded,
                size: 21,
                color: ShellColors.accent,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Modalità energetiche',
                  style: ShellText.cardTitle,
                ),
              ),
              _DashboardIconButton(
                semanticLabel: 'Aggiorna modalità energetiche',
                icon: Icons.refresh_rounded,
                busy: modes.refreshing,
                enabled: !modes.systemChanging && !modes.pboChanging,
                onTap: () => unawaited(controller.refresh()),
              ),
            ],
          ),
          const SizedBox(height: 11),
          _PowerModeRow(
            label: 'Sistema',
            available: modes.systemAvailable,
            checking: modes.refreshing,
            children: [
              _PowerModeOption(
                semanticLabel: 'Profilo di sistema Risparmio energetico',
                icon: Icons.energy_savings_leaf_rounded,
                selected: modes.systemProfile == PowerProfile.powerSave,
                busy: modes.systemChanging &&
                    modes.systemProfile == PowerProfile.powerSave,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.powerSave),
                ),
              ),
              _PowerModeOption(
                semanticLabel: 'Profilo di sistema Bilanciato',
                icon: Icons.balance_rounded,
                selected: modes.systemProfile == PowerProfile.balanced,
                busy: modes.systemChanging &&
                    modes.systemProfile == PowerProfile.balanced,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.balanced),
                ),
              ),
              _PowerModeOption(
                semanticLabel: 'Profilo di sistema Prestazioni',
                icon: Icons.rocket_launch_rounded,
                selected: modes.systemProfile == PowerProfile.performance,
                busy: modes.systemChanging &&
                    modes.systemProfile == PowerProfile.performance,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.performance),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _PowerModeRow(
            label: 'PBO',
            available: modes.pboAvailable,
            checking: modes.refreshing,
            children: [
              _PowerModeOption(
                semanticLabel: 'PBO Silenzioso',
                icon: Icons.bedtime_rounded,
                selected: modes.pboProfile == DesktopPboProfile.silent,
                busy: modes.pboChanging &&
                    modes.pboProfile == DesktopPboProfile.silent,
                enabled: pboEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectPboProfile(DesktopPboProfile.silent),
                ),
              ),
              _PowerModeOption(
                semanticLabel: 'PBO Bilanciato',
                icon: Icons.balance_rounded,
                selected: modes.pboProfile == DesktopPboProfile.balanced,
                busy: modes.pboChanging &&
                    modes.pboProfile == DesktopPboProfile.balanced,
                enabled: pboEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectPboProfile(DesktopPboProfile.balanced),
                ),
              ),
              _PowerModeOption(
                semanticLabel: 'PBO Prestazioni',
                icon: Icons.speed_rounded,
                selected: modes.pboProfile == DesktopPboProfile.performance,
                busy: modes.pboChanging &&
                    modes.pboProfile == DesktopPboProfile.performance,
                enabled: pboEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectPboProfile(DesktopPboProfile.performance),
                ),
              ),
            ],
          ),
          if (modes.error case final error?) ...[
            const SizedBox(height: 9),
            Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShellText.cardTitle.copyWith(
                color: ShellColors.performanceBad,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PowerModeRow extends StatelessWidget {
  const _PowerModeRow({
    required this.label,
    required this.available,
    required this.checking,
    required this.children,
  });

  final String label;
  final bool available;
  final bool checking;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final availability = checking && !available
        ? 'verifica…'
        : available
            ? null
            : 'non disponibile';
    return Row(
      children: [
        Expanded(
          child: Text(
            availability == null ? label : '$label · $availability',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShellText.cardTitle.copyWith(
              color: available
                  ? ShellColors.textSecondary
                  : ShellColors.textTertiary,
              fontSize: 12,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.surfaceContainer,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: ShellColors.hairlineSoft),
          ),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ],
    );
  }
}

class _PowerModeOption extends StatefulWidget {
  const _PowerModeOption({
    required this.semanticLabel,
    required this.icon,
    required this.selected,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.secondary = false,
  });

  final String semanticLabel;
  final IconData icon;
  final bool selected;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final bool secondary;

  @override
  State<_PowerModeOption> createState() => _PowerModeOptionState();
}

class _PowerModeOptionState extends State<_PowerModeOption> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final actionable = widget.enabled && !widget.busy;
    final selectedBackground = widget.secondary
        ? ShellColors.secondaryContainer
        : ShellColors.primaryContainer;
    final selectedForeground = widget.secondary
        ? ShellColors.onSecondaryContainer
        : ShellColors.onPrimaryContainer;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.busy
            ? ShellMouseCursors.working
            : actionable
                ? ShellMouseCursors.link
                : ShellMouseCursors.normal,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (actionable) {
                widget.onTap();
              }
              return null;
            },
          ),
        },
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: actionable ? widget.onTap : null,
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            width: 36,
            height: 32,
            decoration: BoxDecoration(
              color: widget.selected
                  ? selectedBackground
                  : _hovered
                      ? ShellColors.surfaceContainerHighest
                      : const Color(0x00000000),
              borderRadius: BorderRadius.circular(12),
              border: _focused
                  ? Border.all(color: ShellColors.accent, width: 1.5)
                  : null,
            ),
            child: widget.busy
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ShellColors.accent,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 18,
                    color: !widget.enabled
                        ? ShellColors.glyphInactive
                        : widget.selected
                            ? selectedForeground
                            : ShellColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _BluetoothDeviceList extends StatelessWidget {
  const _BluetoothDeviceList({
    required this.state,
    required this.onToggleConnection,
  });

  final BluetoothState state;
  final ValueChanged<BluetoothDeviceInfo> onToggleConnection;

  @override
  Widget build(BuildContext context) {
    if (state.refreshing && state.devices.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: ShellColors.accent,
          ),
        ),
      );
    }
    if (!state.available) {
      return const _DashboardEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        label: 'Bluetooth non disponibile',
      );
    }
    if (!state.powered) {
      return const _DashboardEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        label: 'Attiva Bluetooth per vedere i dispositivi',
      );
    }
    if (state.devices.isEmpty) {
      return _DashboardEmptyState(
        icon: state.scanning
            ? Icons.bluetooth_searching_rounded
            : Icons.bluetooth_rounded,
        label: state.scanning
            ? 'Ricerca dispositivi…'
            : 'Nessun dispositivo trovato',
      );
    }

    return ListView.separated(
      itemCount: state.devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final device = state.devices[index];
        return _BluetoothDeviceRow(
          device: device,
          busy: state.busyDevices.contains(device.objectPath),
          onTap: () => onToggleConnection(device),
        );
      },
    );
  }
}

class _DashboardEmptyState extends StatelessWidget {
  const _DashboardEmptyState({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: ShellColors.textTertiary),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: ShellText.cardTitle.copyWith(
              color: ShellColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BluetoothDeviceRow extends StatefulWidget {
  const _BluetoothDeviceRow({
    required this.device,
    required this.busy,
    required this.onTap,
  });

  final BluetoothDeviceInfo device;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_BluetoothDeviceRow> createState() => _BluetoothDeviceRowState();
}

class _BluetoothDeviceRowState extends State<_BluetoothDeviceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final status = device.connected
        ? 'Connesso'
        : device.paired
            ? 'Associato'
            : 'Disponibile';
    return Semantics(
      button: true,
      label: '${device.connected ? 'Disconnetti' : 'Connetti'} ${device.name}',
      child: MouseRegion(
        cursor:
            widget.busy ? ShellMouseCursors.working : ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.busy ? null : widget.onTap,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: device.connected
                  ? ShellColors.primaryContainer
                  : _hovered
                      ? ShellColors.surfaceContainerHighest
                      : ShellColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  _bluetoothIcon(device.icon),
                  size: 22,
                  color: device.connected
                      ? ShellColors.onPrimaryContainer
                      : ShellColors.textPrimary,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.cardTitle,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status,
                        style: ShellText.cardTitle.copyWith(
                          color: device.connected
                              ? ShellColors.onPrimaryContainerSecondary
                              : ShellColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.busy)
                  const SizedBox(
                    width: 21,
                    height: 21,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ShellColors.accent,
                    ),
                  )
                else
                  Icon(
                    device.connected ? Icons.link_off_rounded : Icons.link,
                    size: 20,
                    color: device.connected
                        ? ShellColors.onPrimaryContainer
                        : ShellColors.textSecondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardIconButton extends StatefulWidget {
  const _DashboardIconButton({
    required this.semanticLabel,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.busy = false,
    this.enabled = true,
  });

  final String semanticLabel;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool busy;
  final bool enabled;

  @override
  State<_DashboardIconButton> createState() => _DashboardIconButtonState();
}

class _DashboardIconButtonState extends State<_DashboardIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: widget.busy
            ? ShellMouseCursors.working
            : widget.enabled
                ? ShellMouseCursors.link
                : ShellMouseCursors.normal,
        onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled && !widget.busy ? widget.onTap : null,
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: widget.active
                  ? ShellColors.primaryContainer
                  : _hovered
                      ? ShellColors.surfaceContainerHighest
                      : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: widget.busy
                ? const Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ShellColors.accent,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 18,
                    color: widget.enabled
                        ? ShellColors.textPrimary
                        : ShellColors.glyphInactive,
                  ),
          ),
        ),
      ),
    );
  }
}

class _DashboardValueButton extends StatefulWidget {
  const _DashboardValueButton({
    required this.semanticLabel,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String semanticLabel;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_DashboardValueButton> createState() => _DashboardValueButtonState();
}

class _DashboardValueButtonState extends State<_DashboardValueButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: _hovered || _focused
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? ShellColors.accent : ShellColors.hairlineSoft,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 7),
                Icon(
                  widget.icon,
                  size: 16,
                  color: ShellColors.accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopAppLauncher extends ConsumerStatefulWidget {
  const _DesktopAppLauncher({
    required this.searchFocusNode,
    required this.onEnter,
    required this.onExit,
    required this.onLaunch,
  });

  final FocusNode searchFocusNode;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final ValueChanged<DesktopApp> onLaunch;

  @override
  ConsumerState<_DesktopAppLauncher> createState() =>
      _DesktopAppLauncherState();
}

class _DesktopAppLauncherState extends ConsumerState<_DesktopAppLauncher> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()
      ..addListener(_handleSearchChanged);
    widget.searchFocusNode.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    widget.searchFocusNode.removeListener(_handleSearchChanged);
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    setState(() {});
  }

  void _clearSearch() {
    _searchController.clear();
    widget.searchFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final allApps = _installedApps(ref.watch(homeGridControllerProvider));
    final apps = _filterInstalledApps(allApps, _searchController.text);
    final searching = _searchController.text.trim().isNotEmpty;
    return MouseRegion(
      onEnter: (_) => widget.onEnter(),
      onExit: (_) => widget.onExit(),
      child: FocusTraversalGroup(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.panelBackground,
            borderRadius: BorderRadius.circular(ShellRadii.panel),
            border: Border.all(color: ShellColors.hairline),
            boxShadow: const [
              BoxShadow(
                color: ShellColors.shadow,
                blurRadius: 36,
                spreadRadius: 3,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Applicazioni',
                  style: ShellText.statusClock.copyWith(fontSize: 22),
                ),
                const SizedBox(height: 4),
                Text(
                  searching
                      ? '${apps.length} risultati su ${allApps.length}'
                      : '${allApps.length} installate',
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                _DesktopAppSearchField(
                  controller: _searchController,
                  focusNode: widget.searchFocusNode,
                  onClear: _clearSearch,
                  onSubmit: () {
                    if (searching && apps.isNotEmpty) {
                      widget.onLaunch(apps.first);
                    }
                  },
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: allApps.isEmpty
                      ? const Center(child: Text('Caricamento applicazioni…'))
                      : apps.isEmpty
                          ? const _DesktopAppSearchEmptyState()
                          : GridView.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 112,
                                mainAxisExtent: 112,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                              itemCount: apps.length,
                              itemBuilder: (context, index) => _DesktopAppTile(
                                app: apps[index],
                                selected: searching && index == 0,
                                onTap: () => widget.onLaunch(apps[index]),
                              ),
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopAppSearchField extends StatelessWidget {
  const _DesktopAppSearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.text.isNotEmpty;
    return Semantics(
      textField: true,
      label: 'Cerca applicazioni',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          border: Border.all(
            color:
                focusNode.hasFocus ? ShellColors.accent : ShellColors.hairline,
          ),
        ),
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: ShellColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (!hasQuery)
                        const IgnorePointer(
                          child: Text(
                            'Cerca applicazioni',
                            style: TextStyle(
                              color: ShellColors.textTertiary,
                              fontSize: 14,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      EditableText(
                        controller: controller,
                        focusNode: focusNode,
                        mouseCursor: ShellMouseCursors.text,
                        autofocus: true,
                        maxLines: 1,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.search,
                        onEditingComplete: () {},
                        onSubmitted: (_) => onSubmit(),
                        style: ShellText.base,
                        cursorColor: ShellColors.accent,
                        backgroundCursorColor: ShellColors.textSecondary,
                        selectionColor: ShellColors.primaryContainer,
                      ),
                    ],
                  ),
                ),
                if (hasQuery) ...[
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: 'Cancella ricerca',
                    child: MouseRegion(
                      cursor: ShellMouseCursors.link,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onClear,
                        child: const SizedBox.square(
                          dimension: 28,
                          child: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: ShellColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopAppSearchEmptyState extends StatelessWidget {
  const _DesktopAppSearchEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.search_off_rounded,
            size: 34,
            color: ShellColors.textTertiary,
          ),
          const SizedBox(height: 10),
          Text(
            'Nessuna applicazione trovata',
            style: ShellText.cardTitle.copyWith(
              color: ShellColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopAppTile extends StatefulWidget {
  const _DesktopAppTile({
    required this.app,
    required this.selected,
    required this.onTap,
  });

  final DesktopApp app;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DesktopAppTile> createState() => _DesktopAppTileState();
}

class _DesktopAppTileState extends State<_DesktopAppTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: 'Launch ${widget.app.name}',
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? ShellColors.primaryContainer
                  : _hovered
                      ? ShellColors.surfaceContainerHighest
                      : const Color(0x00000000),
              borderRadius: BorderRadius.circular(18),
              border: widget.selected
                  ? Border.all(color: ShellColors.accent)
                  : null,
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 54,
                  height: 54,
                  child: AppIconImage(iconPath: widget.app.iconPath),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    widget.app.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: ShellText.cardTitle.copyWith(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _bluetoothIcon(String icon) {
  final normalized = icon.toLowerCase();
  if (normalized.contains('head') || normalized.contains('audio')) {
    return Icons.headphones_rounded;
  }
  if (normalized.contains('gaming')) {
    return Icons.sports_esports_rounded;
  }
  if (normalized.contains('keyboard')) {
    return Icons.keyboard_rounded;
  }
  if (normalized.contains('mouse')) {
    return Icons.mouse_rounded;
  }
  if (normalized.contains('phone')) {
    return Icons.smartphone_rounded;
  }
  if (normalized.contains('computer')) {
    return Icons.computer_rounded;
  }
  return Icons.bluetooth_rounded;
}

List<DesktopApp> _installedApps(AsyncValue<HomeGridState> state) {
  final byId = <String, DesktopApp>{};
  for (final item in state.asData?.value.slots.whereType<HomeGridItem>() ??
      const <HomeGridItem>[]) {
    if (item.app case final app?) {
      byId[app.id] = app;
    }
  }
  final apps = byId.values.toList(growable: false)
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return apps;
}

List<DesktopApp> _filterInstalledApps(
  List<DesktopApp> apps,
  String query,
) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) {
    return apps;
  }

  return apps.where((app) {
    final searchable = <String>[
      app.name,
      app.id,
      ...app.categories,
    ].join(' ').toLowerCase();
    return searchable.contains(normalizedQuery);
  }).toList(growable: false);
}
