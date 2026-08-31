import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../launcher/controllers/application_recents_controller.dart';
import '../launcher/controllers/home_grid_controller.dart';
import '../launcher/models/desktop_app.dart';
import '../launcher/models/home_grid_item.dart';
import '../launcher/widgets/home_tiles.dart';
import '../local_apps/local_flutter_application.dart';
import '../local_apps/local_flutter_window_host.dart';
import '../input/shell_interaction_registry.dart';
import '../localization/denial_localizations.dart';
import '../models/display_layout.dart';
import '../models/denial_window.dart';
import '../platform/denial_bridge.dart';
import '../services/audio_service.dart';
import '../services/bluetooth_service.dart';
import '../services/desktop_power_modes_service.dart';
import '../services/haptics_service.dart';
import '../services/lact_service.dart';
import '../services/power_profile_service.dart';
import '../settings/settings_application.dart';
import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import '../settings/widgets/settings_navigation.dart';
import '../state/app_audio.dart';
import '../state/audio_devices.dart';
import '../state/bluetooth.dart';
import '../state/clipboard_tray.dart';
import '../state/desktop_power_modes.dart';
import '../state/desktop_notifications.dart';
import '../state/desktop_window_close_effect.dart';
import '../state/desktop_window_switcher.dart';
import '../state/display_layout.dart';
import '../state/quick_settings.dart';
import '../state/screenshot_selection.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/clipboard_tray_layer.dart';
import '../widgets/desktop_window_close_animation.dart';
import '../widgets/desktop_window_switcher.dart';
import '../widgets/desktop_window_reveal.dart';
import '../widgets/main_output_centered_surface.dart';
import '../widgets/notification_center.dart';
import '../widgets/retained_translation.dart';
import '../widgets/session/power_session_surface.dart';
import '../widgets/shell_backdrop_blur.dart';
import 'window_backdrop_blur_policy.dart';
import '../widgets/shell_cursor.dart';
import '../widgets/shell_frame_time_overlay.dart';
import '../widgets/shell_surface_host.dart';
import '../widgets/shell_wallpaper.dart';
import '../widgets/window_surface_tree.dart';
import '../widgets/shade/range_bar.dart';
import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/widgets/wallpaper_selector_surface.dart';
import 'desktop_overview_preview_interaction.dart';
import 'desktop_audio_device_dropdown.dart';
import 'desktop_overview_layout.dart';
import 'desktop_overview_target.dart';
import 'desktop_home_layout.dart';
import 'desktop_minimize_layer_handoff.dart';
import 'desktop_panel_hover_controller.dart';
import 'desktop_panel_transition.dart';
import 'desktop_pixel_alignment.dart';
import 'retained_animated_positioned.dart';
import 'desktop_system_bar.dart';
import 'system_tray_module.dart';
import 'desktop_texture_resize.dart';
import 'desktop_window_coordinator.dart';
import 'desktop_window_frame_painter.dart';
import 'desktop_window_render_telemetry.dart';
import 'desktop_workspace.dart';

part 'desktop_application_launcher.dart';
part 'desktop_application_launcher_components.dart';
part 'desktop_app_volume_manager.dart';
part 'desktop_dashboard.dart';
part 'desktop_dashboard_bluetooth.dart';
part 'desktop_dashboard_controls.dart';
part 'desktop_dashboard_power_modes.dart';
part 'desktop_panel_overlay.dart';
part 'desktop_scene.dart';
part 'desktop_scene_layers.dart';
part 'desktop_window_frame.dart';

const desktopApplicationSuggestionsRowKey = ValueKey<String>(
  'desktop-application-suggestions-row',
);
const desktopApplicationSuggestionsDividerKey = ValueKey<String>(
  'desktop-application-suggestions-divider',
);
const desktopDashboardBluetoothMaxHeight = 240.0;

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

final Expando<Set<int>> _desktopSceneLivePlacementObjectIds = Expando<Set<int>>(
  'desktopSceneLivePlacementObjectIds',
);

_DesktopSceneWindows _desktopSceneWindows(
  List<DenialWindow> windows,
  Set<int> livePlacementObjectIds,
) {
  final selection = _DesktopSceneWindows(windows);
  _desktopSceneLivePlacementObjectIds[selection] = Set<int>.unmodifiable(
    livePlacementObjectIds,
  );
  return selection;
}

class _DesktopSceneWindows {
  // Structural scene invalidation deliberately excludes window titles. During
  // a native grab it also excludes live buffer geometry for the grabbed
  // windows. Each keyed frame and popup layer selects its own current window.
  _DesktopSceneWindows(List<DenialWindow> windows)
    : windows = List<DenialWindow>.unmodifiable(
        windows.where(
          (window) => window.isUserApp || window.isInputMethodPopup,
        ),
      );

  final List<DenialWindow> windows;

  @override
  bool operator ==(Object other) {
    final livePlacementObjectIds =
        _desktopSceneLivePlacementObjectIds[this] ?? const <int>{};
    final otherLivePlacementObjectIds = other is _DesktopSceneWindows
        ? _desktopSceneLivePlacementObjectIds[other] ?? const <int>{}
        : const <int>{};
    if (other is! _DesktopSceneWindows ||
        !setEquals(otherLivePlacementObjectIds, livePlacementObjectIds) ||
        other.windows.length != windows.length) {
      return false;
    }
    for (var index = 0; index < windows.length; index += 1) {
      final window = windows[index];
      final otherWindow = other.windows[index];
      final livePlacement =
          livePlacementObjectIds.contains(window.objectId) &&
          otherLivePlacementObjectIds.contains(otherWindow.objectId);
      if (livePlacement
          ? !window.hasSameStaticSceneRoleAs(otherWindow)
          : !window.hasSameSceneDescriptionAs(otherWindow)) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => runtimeType.hashCode;
}

class _DesktopSceneWorkspace {
  const _DesktopSceneWorkspace(this.state);

  final DesktopWorkspaceState state;

  @override
  bool operator ==(Object other) {
    return other is _DesktopSceneWorkspace &&
        desktopWorkspaceHasSameSceneStructure(state, other.state);
  }

  @override
  int get hashCode => Object.hash(
    state.nextZ,
    state.viewSize,
    identityHashCode(state.overview),
    state.placements.length,
  );
}

typedef _DesktopSceneTopology = ({
  Map<int, DenialWindow> windowsById,
  List<DenialWindow> inputMethodPopups,
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

class _DesktopShellState extends ConsumerState<DesktopShell> {
  late final DesktopPanelHoverController _panelHoverController;
  Timer? _wallpaperOpenTimer;
  Timer? _windowSwitcherHoldTimer;
  Timer? _windowSwitcherCleanupTimer;
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
      case DenialShellAction.dashboard:
        _toggleDashboard();
      case DenialShellAction.overview:
        _cancelWindowSwitcher();
        _toggleOverview(event.monitorId);
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
    }
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

    final shell = ref.read(shellControllerProvider);
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
      workspace.closeOverview();
      return;
    }

    final viewSize = workspaceState.viewSize.isEmpty
        ? MediaQuery.sizeOf(context)
        : workspaceState.viewSize;
    final displayLayout = ref.read(displayLayoutProvider);
    final shellState = ref.read(shellControllerProvider);
    final target = DesktopOverviewTarget.resolve(
      viewSize: viewSize,
      displayLayout: displayLayout,
      windows: shellState.openAppWindows,
      workspace: workspaceState,
      foregroundObjectId: shellState.foregroundObjectId,
      preferredMonitorId: preferredMonitorId,
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
    ref
        .read(shellSurfaceControllerProvider.notifier)
        .show(
          keyName: 'application-volume-manager',
          debugLabel: 'Application volume manager',
          pointerPolicy: ShellPointerPolicy.fullScene,
          keyboardPolicy: ShellKeyboardPolicy.capture,
          dismissPolicy: ShellDismissPolicy.outsideTapAndEscape,
          builder: (_, handle) =>
              _AppVolumeManagerSurface(onDismiss: handle.close),
        );
  }

  void _openSettings() {
    _openSettingsPage(null);
  }

  void _openPowerSettings() {
    _openSettingsPage(SettingsPageId.power);
  }

  void _openSettingsPage(SettingsPageId? page) {
    final environment = ref.read(startupEnvironmentProvider);
    if (environment.flag('DENIA_EMBED_SETTINGS')) {
      if (page != null) {
        ref.read(settingsPageOpenRequestProvider.notifier).request(page);
      }
      _launchLocalApp(denialSettingsApplication);
      return;
    }
    _closePanels();
    for (final window in ref.read(shellControllerProvider).openAppWindows) {
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
        ? '/usr/bin/denial-settings'
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

  void _beginOverviewDrag(DenialWindow window) {
    ref
        .read(desktopWorkspaceProvider.notifier)
        .beginOverviewDrag(window.objectId);
  }

  void _updateOverviewDrag(DenialWindow window, Offset delta) {
    ref
        .read(desktopWorkspaceProvider.notifier)
        .moveOverviewBy(window.objectId, delta);
  }

  void _endOverviewDrag(DenialWindow window) {
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
      if (placement != null) {
        ref
            .read(denialBridgeProvider)
            .configureWindow(window, placement.contentRect, layoutDrop: true);
      }
      ref.read(shellControllerProvider.notifier).focusWindow(window);
    }
  }

  void _cancelOverviewDrag(DenialWindow window) {
    ref
        .read(desktopWorkspaceProvider.notifier)
        .cancelOverviewDrag(window.objectId);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopWindowCoordinatorProvider);
    ref.listen<int?>(
      shellControllerProvider.select((state) => state.foregroundObjectId),
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
        .watch(desktopWorkspaceProvider.select(_DesktopSceneWorkspace.new))
        .state;
    final livePlacementObjectIds = <int>{
      for (final placement in desktop.placements.values)
        if (placement.dragging) placement.objectId,
    };
    final windows = ref
        .watch(
          shellControllerProvider.select(
            (state) =>
                _desktopSceneWindows(state.windows, livePlacementObjectIds),
          ),
        )
        .windows;
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
    // DENIA_SHELL_DEV_LAYOUT lets the shell run as an ordinary Wayland client
    // (no native bridge) while still rendering layout-dependent chrome such
    // as the system bar, for styling work without restarting deniald.
    final displayLayout =
        nativeDisplayLayout ??
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
      style: context.shellTheme.text.base,
      child: ColoredBox(
        color: context.shellColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) => _DesktopScene(
            viewSize: constraints.biggest,
            windows: windows,
            desktop: desktop,
            closeEffect: animations.windowCloseEffect,
            minimizedWindowPlacement: minimizedWindowPlacement,
            panelTravel: animations.panelTravel,
            panelDurationScale: animations.durationScale,
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
            onOpenSettings: _openSettings,
            onOpenPowerSettings: _openPowerSettings,
            onCancelPanelClose: _cancelPanelClose,
            onSchedulePanelClose: _schedulePanelClose,
            onPanelOpened: _panelHoverController.openingCompleted,
            onLaunchApp: _launchApp,
            onLaunchLocalApp: _launchLocalApp,
            onActivateWindow: _activateWindow,
            onOverviewBarrierTap: _handleOverviewBarrierTap,
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
    );
  }
}

/// The independently clipped system-bar clones. No rect may cross an output
/// boundary, so selecting adjacent displays never creates a spanning bar.
List<({int monitorId, Rect rect, SystemBarSide side})> _systemBarGeometries(
  Size viewSize,
  DisplayLayout? displayLayout,
) {
  if (displayLayout == null || !displayLayout.systemBarActive) {
    return const <({int monitorId, Rect rect, SystemBarSide side})>[];
  }
  return <({int monitorId, Rect rect, SystemBarSide side})>[
    for (final output in displayLayout.systemBarOutputs)
      if (DesktopMetrics.systemBarRect(
            viewSize,
            displayLayout.systemBarRectFor(output),
          )
          case final rect when !rect.isEmpty)
        (
          monitorId: output.monitorId,
          rect: rect,
          side: displayLayout.systemBarSide,
        ),
  ];
}

Rect _windowSwitcherStageBounds({
  required Size viewSize,
  required DisplayLayout? displayLayout,
  required DesktopWorkspaceState desktop,
  required DesktopWindowSwitcherState switcher,
}) {
  final canvas = Offset.zero & viewSize;
  final sourcePlacement =
      desktop.placements[switcher.sourceObjectId ?? switcher.selectedObjectId];
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
