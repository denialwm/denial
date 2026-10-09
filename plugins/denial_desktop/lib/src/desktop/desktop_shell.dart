import 'dart:async';

import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/shell_plugin_services.dart';
import '../features/default_shell/panel_composition.dart';
import '../settings/settings_application.dart';
import '../settings/widgets/settings_navigation.dart';
import '../state/clipboard_tray.dart';
import '../state/desktop_visibility.dart';
import '../state/desktop_window_switcher.dart';
import '../state/quick_settings.dart';
import '../widgets/shell_frame_time_overlay.dart';
import 'desktop_overview_keyboard.dart';
import 'desktop_overview_layout.dart';
import 'desktop_overview_target.dart';
import 'desktop_panel_hover_controller.dart';
import 'desktop_scene.dart';
import 'desktop_scene_selection.dart';
import 'desktop_window_coordinator.dart';
import 'desktop_workspace.dart';
import 'system_tray_module.dart';

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  late final DesktopPanelHoverController _panelHoverController;
  Timer? _windowSwitcherHoldTimer;
  Timer? _windowSwitcherCleanupTimer;
  final Map<int, Timer> _workspaceTransitionTimers = <int, Timer>{};
  // Rust only focuses windows on a visible workspace. Activating one on
  // another workspace first switches there, then completes once the
  // compositor reports the new active workspace.
  ({int monitorId, int workspaceId, int? objectId})? _pendingWorkspaceRequest;
  Timer? _pendingWorkspaceRequestTimer;
  // The native drop preview requested for the current workspace-overview
  // drag. Rust keeps planning it until a commit or an explicit end.
  ({DenialWindow window, int monitorId, int workspaceId, Offset point})?
  _overviewDropPreview;
  final FocusNode _applicationSearchFocusNode = FocusNode(
    debugLabel: 'desktop-application-search',
  );
  late final StreamSubscription<DenialShellActionEvent>
  _shellActionSubscription;

  @override
  void initState() {
    super.initState();
    _panelHoverController = DesktopPanelHoverController(onClose: _closePanels);
    ref.read(hapticsServiceProvider).prewarm();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // Hardware-backed dashboard state should settle while the desktop is
      // idle, not during the first panel entrance animation. Deferring it
      // until after the first frame keeps startup's critical frame lean.
      ref.read(quickSettingsProvider);
      ref.read(desktopPowerModesProvider);
    });
    _shellActionSubscription = ref
        .read(denialBridgeProvider)
        .shellActions
        .listen(_handleShellAction);
  }

  @override
  void dispose() {
    _panelHoverController.dispose();
    _windowSwitcherHoldTimer?.cancel();
    _windowSwitcherCleanupTimer?.cancel();
    for (final timer in _workspaceTransitionTimers.values) {
      timer.cancel();
    }
    _workspaceTransitionTimers.clear();
    _pendingWorkspaceRequestTimer?.cancel();
    unawaited(_shellActionSubscription.cancel());
    _applicationSearchFocusNode.dispose();
    super.dispose();
  }

  void _handleShellAction(DenialShellActionEvent event) {
    switch (event.action) {
      case DenialShellAction.applications:
      // Legacy wire events cannot bypass plugin action availability.
      case DenialShellAction.dashboard:
        _toggleDashboard();
      case DenialShellAction.overview:
        _cancelWindowSwitcher();
        _toggleOverview(event.monitorId);
      case DenialShellAction.focusLeft:
        _moveOverviewSelection(DesktopOverviewDirection.left);
      case DenialShellAction.focusRight:
        _moveOverviewSelection(DesktopOverviewDirection.right);
      case DenialShellAction.focusUp:
        _moveOverviewSelection(DesktopOverviewDirection.up);
      case DenialShellAction.focusDown:
        _moveOverviewSelection(DesktopOverviewDirection.down);
      case DenialShellAction.windowSwitcherNext:
        _cycleWindowSwitcher(
          event.monitorId,
          direction: DesktopWindowSwitcherDirection.next,
        );
      case DenialShellAction.windowSwitcherPrevious:
        _cycleWindowSwitcher(
          event.monitorId,
          direction: DesktopWindowSwitcherDirection.previous,
        );
      case DenialShellAction.windowSwitcherEnd:
        _finishWindowSwitcher();
      case DenialShellAction.clipboard:
        _toggleClipboardTray(event.monitorId);
      case DenialShellAction.screenshotPrepare:
        final controller = ref.read(screenshotSelectionProvider.notifier);
        if (controller.prepare(event.requestId)) {
          ref.read(denialBridgeProvider).screenshotPrepared(event.requestId);
        }
      case DenialShellAction.screenshotTextureReady:
        final textureId = event.textureId;
        if (textureId != null) {
          ref
              .read(screenshotSelectionProvider.notifier)
              .textureReady(event.requestId, textureId);
        }
      case DenialShellAction.screenshotDone:
        ref.read(screenshotSelectionProvider.notifier).done(event.requestId);
      case DenialShellAction.clientPointerPressed:
        dismissOpenSystemTrayMenu(ref);
      case DenialShellAction.wallpaper:
        unawaited(_showWallpaperSelector());
      case DenialShellAction.openSettings:
        _openSettings();
      case DenialShellAction.workspaceChanged:
        final monitorId = event.monitorId;
        final workspaceId = event.workspaceId;
        if (monitorId != null && workspaceId != null) {
          _workspaceChanged(monitorId, workspaceId);
        }
    }
  }

  void _workspaceChanged(int monitorId, int workspaceId) {
    final controller = ref.read(desktopWorkspaceProvider.notifier);
    final previousTransition = ref
        .read(desktopWorkspaceProvider)
        .workspaceTransitions[monitorId];
    controller.applyWorkspaceChanged(monitorId, workspaceId);
    final transition = ref
        .read(desktopWorkspaceProvider)
        .workspaceTransitions[monitorId];
    if (identical(previousTransition, transition)) return;
    _workspaceTransitionTimers.remove(monitorId)?.cancel();
    if (transition == null) {
      return;
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _workspaceTransitionTimers[monitorId] = Timer(
      reduceMotion ? Duration.zero : Motion.workspaceSwitch,
      () {
        _workspaceTransitionTimers.remove(monitorId);
        if (mounted) {
          controller.finishWorkspaceTransition(monitorId, transition.serial);
        }
      },
    );
  }

  void _toggleClipboardTray(int? monitorId) {
    _cancelWindowSwitcher();
    _closePanels();
    final workspace = ref.read(desktopWorkspaceProvider);
    if (workspace.overviewActive) {
      ref.read(desktopWorkspaceProvider.notifier).closeOverview();
    }
    ref.read(clipboardTrayProvider.notifier).toggle(monitorId: monitorId);
  }

  void _cycleWindowSwitcher(
    int? preferredMonitorId, {
    required DesktopWindowSwitcherDirection direction,
  }) {
    _windowSwitcherCleanupTimer?.cancel();
    _windowSwitcherCleanupTimer = null;
    _panelHoverController.reset();
    _applicationSearchFocusNode.unfocus();

    final shell = ref.read(referenceShellProvider);
    final workspace = ref.read(desktopWorkspaceProvider);
    final windowsById = <int, DenialWindow>{
      for (final window in shell.openAppWindows) window.objectId: window,
    };
    final controller = ref.read(desktopWindowSwitcherProvider.notifier);
    final previous = ref.read(desktopWindowSwitcherProvider);
    if (previous != null && previous.isSelecting) {
      final activeSessionPlacements = previous.objectIds
          .map((objectId) => workspace.placements[objectId])
          .whereType<DesktopWindowPlacement>()
          .where((placement) {
            final objectId = placement.objectId;
            return windowsById.containsKey(objectId) &&
                DesktopOverviewLayout.isUsefulPreview(placement.frame);
          })
          .toList(growable: false);
      final activeSessionIds = activeSessionPlacements
          .map((placement) => placement.objectId)
          .toList(growable: false);
      final visibleSessionIds = activeSessionPlacements
          .where((placement) => !placement.minimized)
          .map((placement) => placement.objectId)
          .toList(growable: false);
      final previousSource = previous.sourceObjectId;
      final int? sourceObjectId;
      if (previousSource != null &&
          visibleSessionIds.contains(previousSource)) {
        sourceObjectId = previousSource;
      } else if (visibleSessionIds.isNotEmpty) {
        sourceObjectId = visibleSessionIds.first;
      } else {
        sourceObjectId = null;
      }
      if (activeSessionIds.isEmpty ||
          (sourceObjectId != null && activeSessionIds.length < 2)) {
        _cancelWindowSwitcher();
        return;
      }
      final next = controller.beginOrAdvance(
        objectIds: activeSessionIds,
        sourceObjectId: sourceObjectId,
        usesDesktopMotion:
            previous.usesDesktopMotion ||
            activeSessionPlacements.any((placement) => placement.minimized),
        direction: direction,
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
    final monitorTarget = DesktopOverviewTarget.resolve(
      viewSize: viewSize,
      displayLayout: displayLayout,
      windows: shell.openAppWindows,
      workspace: workspace,
      foregroundObjectId: shell.foregroundObjectId,
      preferredMonitorId: preferredMonitorId,
    );
    if (monitorTarget == null) {
      return;
    }
    final placements =
        workspace.placements.values
            .where(
              (placement) =>
                  monitorTarget.objectIds.contains(placement.objectId) &&
                  windowsById.containsKey(placement.objectId),
            )
            .toList(growable: false)
          ..sort((left, right) => right.z.compareTo(left.z));
    if (placements.isEmpty) {
      return;
    }

    final placementIds = placements
        .map((placement) => placement.objectId)
        .toList(growable: true);
    final foregroundId = shell.foregroundObjectId;
    final visiblePlacementIds = placements
        .where((placement) => !placement.minimized)
        .map((placement) => placement.objectId)
        .toList(growable: false);
    final int? sourceObjectId;
    if (foregroundId != null && visiblePlacementIds.contains(foregroundId)) {
      sourceObjectId = foregroundId;
    } else if (visiblePlacementIds.isNotEmpty) {
      sourceObjectId = visiblePlacementIds.first;
    } else {
      sourceObjectId = null;
    }
    if (sourceObjectId != null && placementIds.length < 2) {
      return;
    }

    if (workspace.overviewActive) {
      ref.read(desktopWorkspaceProvider.notifier).closeOverview();
    }
    ref.read(desktopWorkspaceProvider.notifier).closePanels();

    final next = controller.beginOrAdvance(
      objectIds: placementIds,
      sourceObjectId: sourceObjectId,
      usesDesktopMotion: placements.any((placement) => placement.minimized),
      direction: direction,
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
    for (final window in ref.read(referenceShellProvider).openAppWindows) {
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
    final expanded = switcher.usesExpandedTransition;
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
    ref.read(clipboardTrayProvider.notifier).close();
    _panelHoverController.reset();
    _applicationSearchFocusNode.unfocus();

    final workspaceState = ref.read(desktopWorkspaceProvider);
    final workspace = ref.read(desktopWorkspaceProvider.notifier);
    if (workspaceState.overviewActive) {
      _activateOverviewSelection();
      return;
    }

    final viewSize = workspaceState.viewSize.isEmpty
        ? MediaQuery.sizeOf(context)
        : workspaceState.viewSize;
    final displayLayout = ref.read(displayLayoutProvider);
    final shellState = ref.read(referenceShellProvider);
    final layout = ref.read(shellSettingsProvider).layout;
    // Stacking windows overlap, so spreading them apart is the useful view.
    // Managed layouts already avoid overlap and their arrangement is the
    // information, so they show true-to-layout workspace miniatures instead.
    final workspaceOverview =
        layout.windowLayout != DesktopWindowLayout.stacking;
    final target = DesktopOverviewTarget.resolve(
      viewSize: viewSize,
      displayLayout: displayLayout,
      windows: shellState.openAppWindows,
      workspace: workspaceState,
      foregroundObjectId: shellState.foregroundObjectId,
      preferredMonitorId: preferredMonitorId,
      allWorkspaces: workspaceOverview,
    );
    if (target == null) {
      return;
    }

    workspace.closePanels();
    if (workspaceOverview) {
      _cancelPendingWorkspaceRequest();
      workspace.openWorkspaceOverview(
        monitorId: target.monitorId,
        bounds: target.bounds,
        backgroundBounds: target.backgroundBounds,
        viewport: target.workArea,
        orientation: layout.workspaceSwitchingOrientation,
        selectedObjectId: shellState.foregroundObjectId,
      );
      return;
    }
    workspace.toggleOverview(
      monitorId: target.monitorId,
      bounds: target.bounds,
      backgroundBounds: target.backgroundBounds,
      objectIds: target.objectIds,
      selectedObjectId: shellState.foregroundObjectId,
    );
  }

  void _moveOverviewSelection(DesktopOverviewDirection direction) {
    final moved = ref
        .read(desktopWorkspaceProvider.notifier)
        .moveOverviewSelection(direction);
    if (moved) {
      ref.read(hapticsServiceProvider).pulse();
    }
  }

  void _activateOverviewSelection() {
    final overview = ref.read(desktopWorkspaceProvider).overview;
    if (overview == null) {
      return;
    }
    final selectedObjectId = overview.selectedObjectId;
    if (selectedObjectId == null) {
      _dismissOverview();
      return;
    }
    for (final window in ref.read(referenceShellProvider).openAppWindows) {
      if (window.objectId == selectedObjectId) {
        _activateWindow(window);
        return;
      }
    }
    ref.read(desktopWorkspaceProvider.notifier).closeOverview();
  }

  void _dismissOverview() {
    _cancelPendingWorkspaceRequest();
    ref.read(desktopWorkspaceProvider.notifier).closeOverview();
  }

  /// Selects a workspace card. The overview closes by zooming into it once
  /// the compositor has made it active.
  void _selectOverviewWorkspace(int monitorId, int workspaceId) {
    final workspace = ref.read(desktopWorkspaceProvider);
    if (workspace.overview?.workspaces == null) {
      return;
    }
    if (workspace.activeWorkspaceFor(monitorId) == workspaceId) {
      _dismissOverview();
      return;
    }
    _requestWorkspace(monitorId, workspaceId);
  }

  void _requestWorkspace(int monitorId, int workspaceId, {int? objectId}) {
    _pendingWorkspaceRequest = (
      monitorId: monitorId,
      workspaceId: workspaceId,
      objectId: objectId,
    );
    // A request the compositor rejects must not complete much later, after
    // the user has moved on.
    _pendingWorkspaceRequestTimer?.cancel();
    _pendingWorkspaceRequestTimer = Timer(
      const Duration(seconds: 1),
      () => _pendingWorkspaceRequest = null,
    );
    ref
        .read(denialBridgeProvider)
        .switchWorkspace(monitorId: monitorId, workspaceId: workspaceId);
  }

  void _cancelPendingWorkspaceRequest() {
    _pendingWorkspaceRequestTimer?.cancel();
    _pendingWorkspaceRequestTimer = null;
    _pendingWorkspaceRequest = null;
  }

  void _completePendingWorkspaceRequest() {
    final request = _pendingWorkspaceRequest;
    if (request == null || !mounted) {
      return;
    }
    final workspace = ref.read(desktopWorkspaceProvider);
    if (workspace.activeWorkspaceFor(request.monitorId) !=
        request.workspaceId) {
      return;
    }
    _cancelPendingWorkspaceRequest();
    final objectId = request.objectId;
    if (objectId != null) {
      for (final window in ref.read(referenceShellProvider).openAppWindows) {
        if (window.objectId == objectId) {
          _activateWindow(window);
          return;
        }
      }
    }
    ref.read(desktopWorkspaceProvider.notifier).closeOverview();
  }

  void _openLauncher() {
    if (ref.read(desktopLauncherProvider) == null) return;
    ref.read(clipboardTrayProvider.notifier).close();
    final workspace = ref.read(desktopWorkspaceProvider);
    if (!workspace.overviewActive && !workspace.launcherOpen) {
      _panelHoverController.beginOpening();
    } else {
      _panelHoverController.cancelClose();
    }
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
    _panelHoverController.reset();
    ref.read(desktopWorkspaceProvider.notifier).closePanels();
    _applicationSearchFocusNode.unfocus();
  }

  void _openDashboard() {
    ref.read(clipboardTrayProvider.notifier).close();
    final workspace = ref.read(desktopWorkspaceProvider);
    if (!workspace.overviewActive && !workspace.dashboardOpen) {
      _panelHoverController.beginOpening();
    } else {
      _panelHoverController.cancelClose();
    }
    _applicationSearchFocusNode.unfocus();
    ref
        .read(desktopWorkspaceProvider.notifier)
        .showPanel(DesktopPanel.dashboard);
    // BlueZ is signal-driven and already initialized at the shell root. Power
    // modes have no equivalent subscription, so only refresh a stale cache.
    unawaited(ref.read(desktopPowerModesProvider.notifier).refreshIfStale());
  }

  void _toggleDashboard() {
    if (ref.read(desktopWorkspaceProvider).dashboardOpen) {
      _closePanels();
      return;
    }
    _openDashboard();
  }

  void _openSettings() {
    _openSettingsPage(null);
  }

  void _openPowerSettings() {
    _openSettingsPage(SettingsPageId.power);
  }

  void _openSettingsPage(SettingsPageId? page) {
    final environment = ref.read(startupEnvironmentProvider);
    _closePanels();
    for (final window in ref.read(referenceShellProvider).openAppWindows) {
      if (isDenialSettingsApplicationId(window.appId)) {
        _activateWindow(window);
        if (page == null) {
          return;
        }
        break;
      }
    }
    final binary = environment['DENIAL_SETTINGS_BINARY']?.trim();
    final executable = binary == null || binary.isEmpty
        ? 'denial-settings'
        : binary;
    ref.read(denialBridgeProvider).launchApplication(<String>[
      executable,
      if (page != null) '--page=${page.name}',
    ]);
  }

  Future<void> _showWallpaperSelector() async {
    var displayLayout = ref.read(displayLayoutProvider);
    displayLayout ??= await ref
        .read(displayLayoutProvider.notifier)
        .ensureLoaded();
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
    _panelHoverController.cancelClose();
  }

  void _schedulePanelClose() {
    _panelHoverController.scheduleClose();
  }

  Future<void> _launchApp(DesktopApp app) async {
    _closePanels();
    ref
        .read(applicationRecentsProvider.notifier)
        .record(desktopApplicationRecentId(app.id));
    await ref.read(appLauncherProvider).launch(app);
  }

  void _launchLocalApp(LocalFlutterApplication app) {
    _closePanels();
    ref
        .read(applicationRecentsProvider.notifier)
        .record(localApplicationRecentId(app.id));
    final displayLayout = ref.read(displayLayoutProvider);
    final mainOutput = displayLayout?.mainOutput;
    final workspace = ref.read(desktopWorkspaceProvider);
    final viewSize = workspace.viewSize.isEmpty
        ? MediaQuery.sizeOf(context)
        : workspace.viewSize;
    final availableBounds = mainOutput == null
        ? Offset.zero & viewSize
        : displayLayout!.workAreaOf(mainOutput);
    ref
        .read(localFlutterApplicationLauncherProvider)
        .launch(
          app.id,
          availableBounds: availableBounds,
          title: app.titleFor(context),
        );
  }

  void _activateWindow(DenialWindow window) {
    final workspace = ref.read(desktopWorkspaceProvider);
    final placement = workspace.placements[window.objectId];
    if (placement != null &&
        !placement.minimized &&
        placement.monitorId >= 0 &&
        !workspace.isPlacementOnActiveWorkspace(placement)) {
      _requestWorkspace(
        placement.monitorId,
        placement.workspaceId,
        objectId: window.objectId,
      );
      return;
    }
    _cancelPendingWorkspaceRequest();
    ref.read(desktopVisibleProvider.notifier).restore();
    ref.read(desktopWorkspaceProvider.notifier).activate(window.objectId);
    ref.read(referenceShellProvider.notifier).focusWindow(window);
  }

  void _handleOverviewBarrierTap(Offset position) {
    final workspace = ref.read(desktopWorkspaceProvider);
    final overview = workspace.overview;
    if (overview == null || overview.backgroundBounds.contains(position)) {
      return;
    }
    final windowsById = <int, DenialWindow>{
      for (final window in ref.read(referenceShellProvider).openAppWindows)
        window.objectId: window,
    };
    final target = desktopWindowAtPosition(
      position: position,
      workspace: workspace,
      windowsById: windowsById,
    );
    _cancelPendingWorkspaceRequest();
    ref.read(desktopWorkspaceProvider.notifier).closeOverview();
    if (target != null) {
      _activateWindow(target);
    }
  }

  void _beginOverviewDrag(DenialWindow window) {
    _endOverviewDropPreview();
    ref
        .read(desktopWorkspaceProvider.notifier)
        .beginOverviewDrag(window.objectId);
  }

  void _updateOverviewDrag(DenialWindow window, Offset delta) {
    ref
        .read(desktopWorkspaceProvider.notifier)
        .moveOverviewBy(window.objectId, delta);
    _previewOverviewDrop(window);
  }

  /// Asks the compositor to plan the drop under the dragged preview, exactly
  /// as a SUPER+drag over a tile would. Its answer arrives as layout-preview
  /// placements, which the overview projects into the cards.
  void _previewOverviewDrop(DenialWindow window) {
    final overview = ref.read(desktopWorkspaceProvider).overview;
    if (overview == null || overview.workspaces == null) {
      return;
    }
    final plan = ref
        .read(desktopWorkspaceProvider.notifier)
        .planOverviewDrop(window.objectId);
    if (plan == null) {
      _endOverviewDropPreview();
      return;
    }
    final point = Offset(
      plan.point.dx.roundToDouble(),
      plan.point.dy.roundToDouble(),
    );
    final previous = _overviewDropPreview;
    if (previous != null &&
        previous.window.objectId == window.objectId &&
        previous.monitorId == overview.monitorId &&
        previous.workspaceId == plan.workspaceId &&
        previous.point == point) {
      return;
    }
    _overviewDropPreview = (
      window: window,
      monitorId: overview.monitorId,
      workspaceId: plan.workspaceId,
      point: point,
    );
    ref
        .read(denialBridgeProvider)
        .previewWindowDropOnWorkspace(
          window,
          monitorId: overview.monitorId,
          workspaceId: plan.workspaceId,
          point: point,
        );
  }

  void _endOverviewDropPreview() {
    final preview = _overviewDropPreview;
    if (preview == null) {
      return;
    }
    _overviewDropPreview = null;
    ref
        .read(denialBridgeProvider)
        .previewWindowDropOnWorkspace(
          preview.window,
          monitorId: preview.monitorId,
          workspaceId: preview.workspaceId,
        );
  }

  void _endOverviewDrag(DenialWindow window) {
    if (_dropOverviewWindowOnWorkspace(window)) {
      return;
    }
    final layout = ref.read(displayLayoutProvider);
    final outputBounds = <int, Rect>{
      for (final output in layout?.outputs ?? const <DisplayOutput>[])
        output.monitorId: output.logicalRect,
    };
    final transferred = ref
        .read(desktopWorkspaceProvider.notifier)
        .endOverviewDrag(
          window.objectId,
          outputBounds: outputBounds,
          workAreas: layout?.workAreasByMonitor() ?? const <int, Rect>{},
        );
    if (transferred) {
      final placement = ref
          .read(desktopWorkspaceProvider)
          .placements[window.objectId];
      // Restore minimized windows to the native layout before submitting the
      // drop. Otherwise Rust treats the still-detached window as floating and
      // acknowledges the free-form rectangle instead of its final tile.
      ref.read(referenceShellProvider.notifier).focusWindow(window);
      if (placement != null) {
        ref
            .read(denialBridgeProvider)
            .configureWindow(window, placement.contentRect, layoutDrop: true);
      }
    }
  }

  /// Handles drops inside a workspace overview's own output. A drop on any
  /// card is a native layout drop onto that workspace: it rearranges tiles on
  /// the window's own workspace, moves it to another one, or restores it from
  /// the shelf, all without leaving the overview. Drops outside the cards
  /// return the preview to its tile. Returns false for drops on other outputs,
  /// which use the ordinary cross-output transfer.
  bool _dropOverviewWindowOnWorkspace(DenialWindow window) {
    final workspace = ref.read(desktopWorkspaceProvider);
    final overview = workspace.overview;
    final preview = overview?.frames[window.objectId];
    if (overview == null ||
        overview.workspaces == null ||
        preview == null ||
        !workspace.placements.containsKey(window.objectId) ||
        !overview.backgroundBounds.contains(preview.center)) {
      _endOverviewDropPreview();
      return false;
    }
    final controller = ref.read(desktopWorkspaceProvider.notifier);
    final plan = controller.planOverviewDrop(window.objectId);
    if (plan == null ||
        !controller.dropOverviewWindowOnWorkspace(
          window.objectId,
          plan.workspaceId,
        )) {
      _endOverviewDropPreview();
      controller.cancelOverviewDrag(window.objectId);
      return true;
    }
    // The commit ends the native preview with each tile's final rectangle.
    _overviewDropPreview = null;
    ref
        .read(denialBridgeProvider)
        .dropWindowOnWorkspace(
          window,
          monitorId: overview.monitorId,
          workspaceId: plan.workspaceId,
          point: plan.point,
        );
    return true;
  }

  void _cancelOverviewDrag(DenialWindow window) {
    _endOverviewDropPreview();
    ref
        .read(desktopWorkspaceProvider.notifier)
        .cancelOverviewDrag(window.objectId);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopWindowCoordinatorProvider);
    ref.listen<Map<int, int>>(
      desktopWorkspaceProvider.select((state) => state.activeWorkspaces),
      (_, _) => scheduleMicrotask(_completePendingWorkspaceRequest),
    );
    ref.listen<bool>(
      desktopWorkspaceProvider.select(
        (state) => state.overview?.workspaces != null,
      ),
      (_, open) {
        if (!open) {
          _endOverviewDropPreview();
        }
      },
    );
    ref.listen<int?>(
      referenceShellProvider.select((state) => state.foregroundObjectId),
      (previous, next) {
        final desktop = ref.read(desktopWorkspaceProvider);
        final nextPlacement = next == null ? null : desktop.placements[next];
        if (next != null &&
            next != previous &&
            !desktop.overviewActive &&
            nextPlacement?.minimized != true) {
          ref.read(desktopWorkspaceProvider.notifier).activate(next);
        }
      },
    );
    final desktop = ref
        .watch(desktopWorkspaceProvider.select(DesktopSceneWorkspace.new))
        .state;
    final livePlacementObjectIds = <int>{
      for (final placement in desktop.placements.values)
        if (placement.dragging) placement.objectId,
    };
    final windows = ref
        .watch(
          referenceShellProvider.select(
            (state) =>
                DesktopSceneWindows(state.windows, livePlacementObjectIds),
          ),
        )
        .windows;
    final layerSurfaces = ref
        .watch(
          referenceShellProvider.select(
            (state) => DesktopSceneLayerSurfaces(state.layerSurfaces),
          ),
        )
        .layerSurfaces;
    final animations = ref.watch(
      shellSettingsProvider.select((settings) => settings.animations),
    );
    final minimizedWindowPlacement = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.layout.minimizedWindowPlacement,
      ),
    );
    final windowSwitcher = ref.watch(desktopWindowSwitcherProvider);
    final nativeDisplayLayout = ref.watch(displayLayoutProvider);
    // DENIAL_SHELL_DEV_LAYOUT lets the shell run as an ordinary Wayland client
    // (no native bridge) while still rendering layout-dependent chrome such
    // as the system bar, for styling work without restarting deniald.
    final displayLayout =
        nativeDisplayLayout ??
        (ref.watch(startupEnvironmentProvider).flag('DENIAL_SHELL_DEV_LAYOUT')
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

    final scene = DefaultTextStyle(
      style: context.shellTheme.text.base,
      child: ColoredBox(
        color: context.shellColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) => DesktopOverviewKeyboard(
            active: desktop.overviewActive,
            onNavigate: _moveOverviewSelection,
            onActivate: _activateOverviewSelection,
            onDismiss: _dismissOverview,
            child: DesktopScene(
              viewSize: constraints.biggest,
              windows: windows,
              layerSurfaces: layerSurfaces,
              desktop: desktop,
              closeEffect: animations.windowCloseEffect,
              minimizedWindowPlacement: minimizedWindowPlacement,
              panelTravel: animations.panelTravel,
              panelDurationScale: animations.durationScale,
              windowSwitcher: windowSwitcher,
              displayLayout: displayLayout,
              showFrameTimingOverlay: ref.watch(
                shellFrameTimingOverlayProvider,
              ),
              wallpaperSelectorVisible: wallpaperSelectorVisible,
              shellOutputRect: shellOutput?.logicalRect,
              mainOutputRect: mainOutput?.logicalRect,
              applicationSearchFocusNode: _applicationSearchFocusNode,
              onOpenLauncher: _openLauncher,
              onDismissLauncher: _closePanels,
              onOpenDashboard: _openDashboard,
              onCloseWallpaperSelector: _closeWallpaperSelector,
              onOpenSettings: _openSettings,
              onOpenPowerSettings: _openPowerSettings,
              onToggleLauncher: _toggleLauncher,
              onCancelPanelClose: _cancelPanelClose,
              onSchedulePanelClose: _schedulePanelClose,
              onPanelOpened: _panelHoverController.openingCompleted,
              onLaunchApp: _launchApp,
              onLaunchLocalApp: _launchLocalApp,
              onActivateWindow: _activateWindow,
              onCloseWindow: ref
                  .read(referenceShellProvider.notifier)
                  .closeWindow,
              onOverviewBarrierTap: _handleOverviewBarrierTap,
              onSelectOverviewWorkspace: _selectOverviewWorkspace,
              onBeginOverviewDrag: _beginOverviewDrag,
              onUpdateOverviewDrag: _updateOverviewDrag,
              onEndOverviewDrag: _endOverviewDrag,
              onCancelOverviewDrag: _cancelOverviewDrag,
              onCloseLeaseComplete: ref
                  .read(denialBridgeProvider)
                  .completeWindowClose,
            ),
          ),
        ),
      ),
    );
    return ShellActionsBinding(
      actions: ref.watch(desktopActionsProvider),
      services: DesktopShellServices(
        ref: ref,
        onOpenPowerSettings: _openPowerSettings,
        onToggleLauncher: _toggleLauncher,
      ),
      child: scene,
    );
  }
}
