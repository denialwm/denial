import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
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
import '../services/bluetooth_service.dart';
import '../services/desktop_power_modes_service.dart';
import '../services/haptics_service.dart';
import '../services/lact_service.dart';
import '../services/audio_service.dart';
import '../services/power_profile_service.dart';
import '../settings/settings_application.dart';
import '../settings/settings_controller.dart';
import '../state/app_audio.dart';
import '../state/bluetooth.dart';
import '../state/clipboard_tray.dart';
import '../state/desktop_power_modes.dart';
import '../state/desktop_notifications.dart';
import '../state/desktop_window_close_effect.dart';
import '../state/desktop_window_switcher.dart';
import '../state/display_layout.dart';
import '../state/quick_settings.dart';
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
import 'desktop_overview_layout.dart';
import 'desktop_overview_target.dart';
import 'desktop_home_layout.dart';
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
        windows.where((window) => window.isUserApp),
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
  int get hashCode => Object.hash(
    Object.hashAll(
      windows.map(
        (window) => Object.hash(
          window.objectId,
          window.windowId,
          window.appId,
          window.pinned,
          window.contentKind,
        ),
      ),
    ),
    Object.hashAllUnordered(
      _desktopSceneLivePlacementObjectIds[this] ?? const <int>{},
    ),
  );
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
    state.panel,
    identityHashCode(state.overview),
    state.placements.length,
  );
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  static const Duration _hoverCloseDelay = Duration(milliseconds: 220);

  Timer? _panelCloseTimer;
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
    ref.read(hapticsServiceProvider).prewarm();
    _shellActionSubscription = ref
        .read(denialBridgeProvider)
        .shellActions
        .listen(_handleShellAction);
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
      case DenialShellAction.clipboard:
        _toggleClipboardTray(event.monitorId);
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
    ref.read(clipboardTrayProvider.notifier).close();
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
    _launchLocalApp(denialSettingsApplication);
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

  void _launchLocalApp(LocalFlutterApplication app) {
    _closePanels();
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
      style: ShellText.base,
      child: ColoredBox(
        color: ShellColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) => _DesktopScene(
            viewSize: constraints.biggest,
            windows: windows,
            desktop: desktop,
            closeEffect: animations.windowCloseEffect,
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
            onCancelPanelClose: _cancelPanelClose,
            onSchedulePanelClose: _schedulePanelClose,
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

typedef _DesktopHomeSceneLayout = ({
  List<HomeGridItem> widgets,
  Map<String, Rect> widgetFrames,
  Map<int, Rect> windowFrames,
});

String _desktopHomeWidgetKey(String id) => 'home-widget:$id';
String _desktopHomeWindowKey(int objectId) => 'home-window:$objectId';

_DesktopHomeSceneLayout _layoutDesktopHome({
  required Size viewSize,
  required DisplayLayout? displayLayout,
  required Iterable<DesktopWindowPlacement> placements,
  required AsyncValue<HomeGridState> homeGrid,
  required bool hasBatteryData,
}) {
  final canvas = Offset.zero & viewSize;
  if (canvas.isEmpty) {
    return (
      widgets: const <HomeGridItem>[],
      widgetFrames: const <String, Rect>{},
      windowFrames: const <int, Rect>{},
    );
  }

  final widgets = <HomeGridItem>[];
  final seenWidgetIds = <String>{};
  for (final item
      in homeGrid.asData?.value.slots.whereType<HomeGridItem>() ??
          const <HomeGridItem>[]) {
    if (item.type != HomeGridItemType.app &&
        (item.type != HomeGridItemType.batteryDischarge || hasBatteryData) &&
        seenWidgetIds.add(item.id)) {
      widgets.add(item);
    }
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

  final widgetFrames = <String, Rect>{};
  final windowFrames = <int, Rect>{};
  for (final area in outputAreas) {
    final outputWindows =
        placementsByMonitor[area.monitorId] ?? const <DesktopWindowPlacement>[];
    final denseWindowMode = DesktopHomeLayout.usesDenseWindowMode(
      outputWindows.length,
    );
    final outputWidgets =
        area.monitorId == fallbackArea.monitorId && !denseWindowMode
        ? widgets
        : const <HomeGridItem>[];
    final frames = DesktopHomeLayout.arrange(
      bounds: area.bounds,
      dense: denseWindowMode,
      items: <DesktopHomeLayoutItem>[
        for (final item in outputWidgets)
          DesktopHomeLayoutItem(
            id: _desktopHomeWidgetKey(item.id),
            preferredAspectRatio: item.colSpan / item.rowSpan,
          ),
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
    for (final item in outputWidgets) {
      final frame = frames[_desktopHomeWidgetKey(item.id)];
      if (frame != null) {
        widgetFrames[item.id] = frame;
      }
    }
    for (final placement in outputWindows) {
      final frame = frames[_desktopHomeWindowKey(placement.objectId)];
      if (frame != null) {
        windowFrames[placement.objectId] = frame;
      }
    }
  }
  return (
    widgets: List<HomeGridItem>.unmodifiable(
      widgets.where((item) => widgetFrames.containsKey(item.id)),
    ),
    widgetFrames: Map<String, Rect>.unmodifiable(widgetFrames),
    windowFrames: Map<int, Rect>.unmodifiable(windowFrames),
  );
}

List<Widget> _buildDesktopWindowLayers({
  required List<DesktopWindowPlacement> placements,
  required Map<int, DenialWindow> windowsById,
  required DesktopWorkspaceState desktop,
  required bool desktopPlane,
  required Map<int, Rect> desktopWidgetFrames,
  required DesktopWindowSwitcherState? switcher,
  required Rect switcherStageBounds,
  required int topZ,
  required bool reduceMotion,
  required Offset Function(DesktopWindowPlacement placement) windowOffsetFor,
  required ValueChanged<DenialWindow> onActivateWindow,
  required ValueChanged<DenialWindow> onBeginOverviewDrag,
  required void Function(DenialWindow window, Offset delta)
  onUpdateOverviewDrag,
  required ValueChanged<DenialWindow> onEndOverviewDrag,
  required ValueChanged<DenialWindow> onCancelOverviewDrag,
}) {
  final layers = <Widget>[];
  for (final placement in placements) {
    final window = windowsById[placement.objectId]!;
    final overview = desktop.isInOverview(placement.objectId);
    final switching =
        !overview &&
        DesktopWindowSwitcherLayout.contains(switcher, placement.objectId);
    final desktopWidget = placement.minimized && !overview && !switching;
    if (desktopWidget != desktopPlane) {
      continue;
    }
    final frame = desktopWidget
        ? desktopWidgetFrames[placement.objectId]
        : switching
        ? DesktopWindowSwitcherLayout.visualFrame(
            placement: placement,
            switcher: switcher,
            stageBounds: switcherStageBounds,
            desktopWidgetFrame: desktopWidgetFrames[placement.objectId],
          )
        : desktop.visualFrame(placement);
    if (frame == null || frame.isEmpty) {
      continue;
    }
    final visible =
        desktopWidget ||
        overview ||
        (switching
            ? DesktopWindowSwitcherLayout.isVisible(
                placement: placement,
                switcher: switcher,
              )
            : true);
    final motionDuration = reduceMotion
        ? Duration.zero
        : desktopWidget
        ? Motion.desktopWindowWidget
        : switching
        ? DesktopWindowSwitcherLayout.motionDuration(switcher!)
        : overview
        ? Motion.overviewOpen
        : Motion.overviewClose;
    final active = switching
        ? DesktopWindowSwitcherLayout.isSelected(switcher, placement.objectId)
        : !overview && !placement.minimized && placement.z == topZ;
    final windowOffset = windowOffsetFor(placement);
    final visualFrame = frame.shift(windowOffset);

    layers.add(
      _DesktopWindowFrame(
        key: ValueKey<int>(placement.objectId),
        window: window,
        placement: placement,
        frame: visualFrame,
        minimized: !visible,
        desktopWidget: desktopWidget,
        overviewActive: desktop.overviewActive,
        overview: overview,
        switching: switching,
        motionDuration: motionDuration,
        active: active,
        onOverviewTap: () => onActivateWindow(window),
        onOverviewDragStart: () => onBeginOverviewDrag(window),
        onOverviewDragUpdate: (delta) => onUpdateOverviewDrag(window, delta),
        onOverviewDragEnd: () => onEndOverviewDrag(window),
        onOverviewDragCancel: () => onCancelOverviewDrag(window),
      ),
    );
    if (!desktopWidget) {
      layers.add(
        _DesktopPopupSurfaceLayers(
          key: ValueKey<String>('desktop-popup-layers-${placement.objectId}'),
          window: window,
          placement: placement,
          frame: visualFrame,
          minimized: !visible,
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

class _DesktopScene extends ConsumerStatefulWidget {
  const _DesktopScene({
    required this.viewSize,
    required this.windows,
    required this.desktop,
    required this.closeEffect,
    required this.panelTravel,
    required this.panelDurationScale,
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
    required this.onOpenSettings,
    required this.onCancelPanelClose,
    required this.onSchedulePanelClose,
    required this.onLaunchApp,
    required this.onLaunchLocalApp,
    required this.onActivateWindow,
    required this.onOverviewBarrierTap,
    required this.onBeginOverviewDrag,
    required this.onUpdateOverviewDrag,
    required this.onEndOverviewDrag,
    required this.onCancelOverviewDrag,
    required this.onCloseLeaseComplete,
  });

  final Size viewSize;
  final List<DenialWindow> windows;
  final DesktopWorkspaceState desktop;
  final DesktopWindowCloseEffect closeEffect;
  final double panelTravel;
  final double panelDurationScale;
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
  final VoidCallback onOpenSettings;
  final VoidCallback onCancelPanelClose;
  final VoidCallback onSchedulePanelClose;
  final ValueChanged<DesktopApp> onLaunchApp;
  final ValueChanged<LocalFlutterApplication> onLaunchLocalApp;
  final ValueChanged<DenialWindow> onActivateWindow;
  final ValueChanged<Offset> onOverviewBarrierTap;
  final ValueChanged<DenialWindow> onBeginOverviewDrag;
  final void Function(DenialWindow window, Offset delta) onUpdateOverviewDrag;
  final ValueChanged<DenialWindow> onEndOverviewDrag;
  final ValueChanged<DenialWindow> onCancelOverviewDrag;
  final ValueChanged<int> onCloseLeaseComplete;

  @override
  ConsumerState<_DesktopScene> createState() => _DesktopSceneState();
}

class _DesktopSceneState extends ConsumerState<_DesktopScene> {
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
        fullscreen:
            placement.fullscreen &&
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
    final overlaySettings = ref.watch(
      shellSettingsProvider.select((settings) => settings.overlays),
    );
    final layoutSettings = ref.watch(
      shellSettingsProvider.select((settings) => settings.layout),
    );
    final clipboardTray = ref.watch(clipboardTrayProvider);
    final viewSize = widget.viewSize;
    final windows = widget.windows;
    final desktop = widget.desktop;
    final windowSwitcher = widget.windowSwitcher;
    final displayLayout = widget.displayLayout;
    Offset clipboardWindowOffsetFor(DesktopWindowPlacement placement) =>
        clipboardTrayWindowOffset(
          clipboardTray,
          layoutSettings,
          monitorId: placement.monitorId,
          displayLayout: displayLayout,
        );
    Offset clipboardClosingWindowOffsetFor(DenialWindow window) =>
        clipboardTrayWindowOffset(
          clipboardTray,
          layoutSettings,
          monitorId: window.monitorId,
          displayLayout: displayLayout,
        );
    final frameTimingOptions = widget.frameTimingOptions;
    final wallpaperSelectorVisible = widget.wallpaperSelectorVisible;
    final shellOutputRect = widget.shellOutputRect;
    final mainOutputRect = widget.mainOutputRect;
    final applicationSearchFocusNode = widget.applicationSearchFocusNode;
    final onOpenLauncher = widget.onOpenLauncher;
    final onDismissLauncher = widget.onDismissLauncher;
    final onOpenDashboard = widget.onOpenDashboard;
    final onOpenSettings = widget.onOpenSettings;
    final onOpenWallpaperSelector = widget.onOpenWallpaperSelector;
    final onCloseWallpaperSelector = widget.onCloseWallpaperSelector;
    final onOpenAppVolumeManager = widget.onOpenAppVolumeManager;
    final onCancelPanelClose = widget.onCancelPanelClose;
    final onSchedulePanelClose = widget.onSchedulePanelClose;
    final onLaunchApp = widget.onLaunchApp;
    final onLaunchLocalApp = widget.onLaunchLocalApp;
    final onActivateWindow = widget.onActivateWindow;
    final onOverviewBarrierTap = widget.onOverviewBarrierTap;
    final onBeginOverviewDrag = widget.onBeginOverviewDrag;
    final onUpdateOverviewDrag = widget.onUpdateOverviewDrag;
    final onEndOverviewDrag = widget.onEndOverviewDrag;
    final onCancelOverviewDrag = widget.onCancelOverviewDrag;
    final windowsById = <int, DenialWindow>{
      for (final window in windows) window.objectId: window,
    };
    final placements =
        desktop.placements.values
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
    final homeLayout = _layoutDesktopHome(
      viewSize: viewSize,
      displayLayout: displayLayout,
      placements: placements,
      homeGrid: ref.watch(homeGridControllerProvider),
      hasBatteryData: ref.watch(
        homeBatteryDischargeProvider.select(
          (series) =>
              series.asData?.value.points.any(
                (point) =>
                    point.capacity != null ||
                    point.currentMa != null ||
                    point.voltageMv != null ||
                    point.powerMw != null,
              ) ??
              false,
        ),
      ),
    );
    final topZ = placements
        .where((placement) => !placement.minimized)
        .fold<int>(0, (value, placement) => math.max(value, placement.z));
    final systemBars = _systemBarGeometries(viewSize, displayLayout);
    final launcherRect = DesktopMetrics.launcherRect(
      viewSize,
      outputRect: shellOutputRect,
      placement: overlaySettings.launcher,
    );
    final dashboardRect = DesktopMetrics.dashboardRect(
      viewSize,
      outputRect: shellOutputRect,
      placement: overlaySettings.dashboard,
    );
    final launcherTriggerRect = DesktopMetrics.launcherTriggerRect(
      viewSize,
      outputRect: shellOutputRect,
      placement: overlaySettings.launcher,
    );
    final dashboardTriggerRect = DesktopMetrics.dashboardTriggerRect(
      viewSize,
      outputRect: shellOutputRect,
      placement: overlaySettings.dashboard,
    );
    // True fullscreen owns the complete output, so the bar yields instead of
    // floating above the fullscreen surface.
    final visibleSystemBars = desktop.overviewActive
        ? systemBars
        : systemBars
              .where(
                (bar) => !placements.any(
                  (placement) =>
                      placement.fullscreen &&
                      !placement.minimized &&
                      placement.monitorId == bar.monitorId,
                ),
              )
              .toList(growable: false);
    final canvas = Offset.zero & viewSize;
    final requestedDisplayRect = mainOutputRect?.intersect(canvas);
    final mainDisplayRect =
        requestedDisplayRect == null || requestedDisplayRect.isEmpty
        ? canvas
        : requestedDisplayRect;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final selectorMotionDuration = reduceMotion
        ? Duration.zero
        : Motion.wallpaperSelector;
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
                  _DesktopWidgetCanvas(
                    widgets: homeLayout.widgets,
                    frames: homeLayout.widgetFrames,
                  ),
                  ..._buildDesktopWindowLayers(
                    placements: placements,
                    windowsById: windowsById,
                    desktop: desktop,
                    desktopPlane: true,
                    desktopWidgetFrames: homeLayout.windowFrames,
                    switcher: windowSwitcher,
                    switcherStageBounds: switcherStageBounds,
                    topZ: topZ,
                    reduceMotion: reduceMotion,
                    windowOffsetFor: clipboardWindowOffsetFor,
                    onActivateWindow: onActivateWindow,
                    onBeginOverviewDrag: onBeginOverviewDrag,
                    onUpdateOverviewDrag: onUpdateOverviewDrag,
                    onEndOverviewDrag: onEndOverviewDrag,
                    onCancelOverviewDrag: onCancelOverviewDrag,
                  ),
                  // The bar belongs to the wallpaper plane. Any window moved
                  // into its reserved strip paints and receives input above it.
                  for (final bar in visibleSystemBars)
                    Positioned.fromRect(
                      key: ValueKey<String>('system-bar-${bar.monitorId}'),
                      rect: bar.rect,
                      child: DesktopSystemBar(side: bar.side),
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
                    desktopPlane: false,
                    desktopWidgetFrames: homeLayout.windowFrames,
                    switcher: windowSwitcher,
                    switcherStageBounds: switcherStageBounds,
                    topZ: topZ,
                    reduceMotion: reduceMotion,
                    windowOffsetFor: clipboardWindowOffsetFor,
                    onActivateWindow: onActivateWindow,
                    onBeginOverviewDrag: onBeginOverviewDrag,
                    onUpdateOverviewDrag: onUpdateOverviewDrag,
                    onEndOverviewDrag: onEndOverviewDrag,
                    onCancelOverviewDrag: onCancelOverviewDrag,
                  ),
                  for (final closing in _closingWindows.values)
                    Positioned.fromRect(
                      key: ValueKey<String>(
                        'desktop-closing-window-${closing.id}',
                      ),
                      rect: closing.frame,
                      child: Transform.translate(
                        offset: clipboardClosingWindowOffsetFor(closing.window),
                        child: _DesktopClosingWindowFrame(
                          closing: closing,
                          onCompleted: () =>
                              _completeCloseAnimation(closing.id),
                        ),
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
                  Positioned.fill(
                    key: const ValueKey<String>(
                      'desktop-launcher-dismiss-barrier',
                    ),
                    child: IgnorePointer(
                      ignoring: !desktop.launcherOpen,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onDismissLauncher,
                      ),
                    ),
                  ),
                  if (!launcherRect.isEmpty)
                    Positioned.fromRect(
                      key: const ValueKey<String>('desktop-launcher-position'),
                      rect: launcherRect,
                      child: _DesktopPanelTransition(
                        key: const ValueKey<String>('desktop-launcher-panel'),
                        inputDebugLabel: 'Desktop application launcher',
                        keyboardPolicy: ShellKeyboardPolicy.capture,
                        visible: desktop.launcherOpen,
                        entryDirection: _entryDirectionFor(
                          overlaySettings.launcher.anchor.horizontal,
                          overlaySettings.launcher.anchor.vertical,
                        ),
                        entryDistance: widget.panelTravel,
                        durationScale: widget.panelDurationScale,
                        child: DesktopApplicationLauncher(
                          searchFocusNode: applicationSearchFocusNode,
                          onEnter: onCancelPanelClose,
                          onExit: onSchedulePanelClose,
                          onLaunch: onLaunchApp,
                          onLaunchLocal: onLaunchLocalApp,
                        ),
                      ),
                    ),
                  if (!dashboardRect.isEmpty)
                    Positioned.fromRect(
                      key: const ValueKey<String>('desktop-dashboard-position'),
                      rect: dashboardRect,
                      child: _DesktopPanelTransition(
                        key: const ValueKey<String>('desktop-dashboard-panel'),
                        inputDebugLabel: 'Desktop dashboard',
                        keyboardPolicy: ShellKeyboardPolicy.capture,
                        visible: desktop.dashboardOpen,
                        entryDirection: _entryDirectionFor(
                          overlaySettings.dashboard.anchor.horizontal,
                          overlaySettings.dashboard.anchor.vertical,
                        ),
                        entryDistance: widget.panelTravel,
                        durationScale: widget.panelDurationScale,
                        child: _DesktopDashboard(
                          onEnter: onCancelPanelClose,
                          onExit: onSchedulePanelClose,
                          onOpenWallpaper: onOpenWallpaperSelector,
                          onOpenAppVolumeManager: onOpenAppVolumeManager,
                          onOpenSettings: onOpenSettings,
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
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final l10n = context.l10n;
    return FocusTraversalGroup(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.panelColor(ShellColors.panelBackground),
          borderRadius: BorderRadius.circular(theme.panelRadius),
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
          borderRadius: BorderRadius.circular(theme.panelRadius),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 18, 16),
                child: Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent.container,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: 42,
                        height: 42,
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          size: 23,
                          color: accent.onContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.desktopApplicationVolumeTitle,
                            style: ShellText.statusClock.copyWith(fontSize: 20),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            l10n.desktopApplicationVolumeDescription,
                            style: ShellText.cardTitle.copyWith(
                              color: ShellColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _DashboardIconButton(
                      semanticLabel: l10n.desktopRefreshApplicationAudio,
                      icon: Icons.refresh_rounded,
                      busy: state.loading,
                      onTap: onRefresh,
                    ),
                    const SizedBox(width: 8),
                    _DashboardIconButton(
                      semanticLabel: l10n.desktopCloseApplicationAudio,
                      icon: Icons.close_rounded,
                      onTap: onDismiss,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: ShellColors.hairlineSoft),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;
    if (state.loading && state.streams.isEmpty) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: ShellTheme.of(context).accent,
          ),
        ),
      );
    }
    if (state.error != null && state.streams.isEmpty) {
      return _AppVolumeManagerMessage(
        icon: Icons.cloud_off_rounded,
        message: l10n.desktopApplicationAudioUnavailable,
        actionLabel: l10n.commonRetry,
        onAction: onRefresh,
      );
    }
    if (state.streams.isEmpty) {
      return _AppVolumeManagerMessage(
        icon: Icons.music_off_rounded,
        message: l10n.desktopNoApplicationAudio,
      );
    }

    return Scrollbar(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
        itemCount: state.streams.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
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
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;
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
        label: l10n.desktopVolumeForApplication(widget.stream.name),
        value: l10n.settingsPercent(percent),
        increasedValue: l10n.settingsPercent(math.min(100, percent + 5)),
        decreasedValue: l10n.settingsPercent(math.max(0, percent - 5)),
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
                color: _focused ? accent : ShellColors.hairlineSoft,
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
                              : accent,
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
                      context.l10n.percentCompact(percent),
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
                  activeColor: accent,
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
    this.entryDirection = const Offset(-1, 0),
    this.entryDistance = 0,
    this.durationScale = 1,
    this.keyboardPolicy = ShellKeyboardPolicy.none,
  });

  final String inputDebugLabel;
  final bool visible;
  final Widget child;
  final Offset entryDirection;
  final double entryDistance;
  final double durationScale;
  final ShellKeyboardPolicy keyboardPolicy;

  @override
  State<_DesktopPanelTransition> createState() =>
      _DesktopPanelTransitionState();
}

class _DesktopPanelTransitionState extends State<_DesktopPanelTransition>
    with SingleTickerProviderStateMixin {
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
      duration: _scaledDuration(Motion.desktopPanelOpen, widget.durationScale),
      reverseDuration: _scaledDuration(
        Motion.desktopPanelClose,
        widget.durationScale,
      ),
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
      ..duration = reduceMotion
          ? Duration.zero
          : _scaledDuration(Motion.desktopPanelOpen, widget.durationScale)
      ..reverseDuration = reduceMotion
          ? Duration.zero
          : _scaledDuration(Motion.desktopPanelClose, widget.durationScale);
  }

  @override
  void didUpdateWidget(covariant _DesktopPanelTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.durationScale != oldWidget.durationScale) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      _controller
        ..duration = reduceMotion
            ? Duration.zero
            : _scaledDuration(Motion.desktopPanelOpen, widget.durationScale)
        ..reverseDuration = reduceMotion
            ? Duration.zero
            : _scaledDuration(Motion.desktopPanelClose, widget.durationScale);
    }
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
      keyboardPolicy: widget.visible
          ? widget.keyboardPolicy
          : ShellKeyboardPolicy.none,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ExcludeSemantics(
          excluding: !widget.visible,
          child: AnimatedBuilder(
            animation: _progress,
            child: RepaintBoundary(
              child: ShellBackdropBlur(
                blur: ShellTheme.of(context).panelOpacity < 1.0,
                borderRadius: BorderRadius.circular(
                  ShellTheme.of(context).panelRadius,
                ),
                child: widget.child,
              ),
            ),
            builder: (context, child) {
              final progress = _progress.value;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final direction = widget.entryDirection;
                  final travel = Offset(
                    direction.dx *
                        (constraints.maxWidth + widget.entryDistance),
                    direction.dy *
                        (constraints.maxHeight + widget.entryDistance),
                  );
                  return Transform.translate(
                    offset: travel * (1.0 - progress),
                    child: child,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DesktopPanelEdgeTrigger extends StatelessWidget {
  const _DesktopPanelEdgeTrigger({required this.onEnter, required this.onExit});

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

Duration _scaledDuration(Duration duration, double scale) {
  return Duration(microseconds: (duration.inMicroseconds * scale).round());
}

Offset _entryDirectionFor(int horizontal, int vertical) {
  if (horizontal != 0) {
    return Offset(horizontal.toDouble(), 0);
  }
  if (vertical != 0) {
    return Offset(0, vertical.toDouble());
  }
  return const Offset(0, 1);
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

class _DesktopWidgetCanvas extends StatelessWidget {
  const _DesktopWidgetCanvas({required this.widgets, required this.frames});

  final List<HomeGridItem> widgets;
  final Map<String, Rect> frames;

  @override
  Widget build(BuildContext context) {
    if (widgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return BackdropGroup(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (final item in widgets)
            if (frames[item.id] case final frame?)
              Positioned.fromRect(
                key: ValueKey<String>('desktop-${item.id}'),
                rect: frame,
                child: _DesktopHomeWidget(item: item),
              ),
        ],
      ),
    );
  }
}

class _DesktopHomeWidget extends StatelessWidget {
  const _DesktopHomeWidget({required this.item});

  final HomeGridItem item;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
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
          : ShellBackdropBlur(
              blur: theme.panelOpacity < 1.0,
              grouped: true,
              borderRadius: BorderRadius.circular(ShellRadii.tile),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.panelColor(ShellColors.panelBackground),
                  borderRadius: BorderRadius.circular(ShellRadii.tile),
                  border: Border.all(color: ShellColors.hairlineSoft),
                ),
                child: content,
              ),
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
    required this.overviewActive,
    required this.overview,
    required this.switching,
    required this.motionDuration,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
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
              shellControllerProvider.select(
                (state) => state.windowByObjectId(this.window.objectId),
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
        final frame = followsLivePlacement
            ? desktopLivePlacementVisualFrame(
                visualFrame: this.frame,
                placementFrame: this.placement.frame,
                livePlacementFrame: placement.frame,
              )
            : this.frame;
        if (window.surfaceLayers.isEmpty) {
          return const SizedBox.shrink();
        }

        final transformed = overview || switching;
        final fullscreenVisual = placement.fullscreen && !transformed;
        final drawsServerFrame =
            !fullscreenVisual && placement.serverSideDecorated;
        final contentRect = drawsServerFrame
            ? frame.deflate(DesktopMetrics.frameBorder)
            : frame;
        final duration = placement.dragging ? Duration.zero : motionDuration;
        final resizing = desktopTextureNeedsResizeSmoothing(
          targetSize: contentRect.size,
          sourceSize: window.contentCoordinateRect.size,
        );
        final filterQuality = transformed || resizing || placement.dragging
            ? FilterQuality.medium
            : FilterQuality.none;

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
                      _DesktopAnimatedWindowPosition(
                        key: ValueKey<int>(layer.surfaceId),
                        duration: duration,
                        rect: window.mapSurfaceRect(layer, contentRect),
                        placementObjectId: placement.objectId,
                        placementFrame: placement.frame,
                        overview: overview,
                        switching: switching,
                        dragging: placement.dragging,
                        child: ShellBackdropBlur(
                          blur: !layer.opaque || layer.opacity < 1.0,
                          child: SurfaceLayerTexture(
                            layer: layer,
                            filterQuality: filterQuality,
                          ),
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
    final radius = drawsServerFrame ? ShellTheme.of(context).windowRadius : 0.0;
    return DesktopWindowCloseAnimation(
      effect: closing.effect,
      seed: Object.hash(closing.window.objectId, closing.id),
      onCompleted: onCompleted,
      child: CustomPaint(
        painter: drawsServerFrame
            ? DesktopWindowFramePainter(
                windowId: closing.window.objectId,
                radius: radius,
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(math.max(0.0, radius - 1.0)),
          child: Padding(
            padding: drawsServerFrame
                ? const EdgeInsets.all(DesktopMetrics.frameBorder)
                : EdgeInsets.zero,
            child: SizedBox.expand(
              child: _DesktopWindowContent(
                window: closing.window,
                smooth: false,
                active: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopWindowFrame extends ConsumerWidget {
  const _DesktopWindowFrame({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.desktopWidget,
    required this.overviewActive,
    required this.overview,
    required this.switching,
    required this.motionDuration,
    required this.active,
    required this.onOverviewTap,
    required this.onOverviewDragStart,
    required this.onOverviewDragUpdate,
    required this.onOverviewDragEnd,
    required this.onOverviewDragCancel,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
  final bool desktopWidget;
  final bool overviewActive;
  final bool overview;
  final bool switching;
  final Duration motionDuration;
  final bool active;
  final VoidCallback onOverviewTap;
  final VoidCallback onOverviewDragStart;
  final ValueChanged<Offset> onOverviewDragUpdate;
  final VoidCallback onOverviewDragEnd;
  final VoidCallback onOverviewDragCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window =
        ref.watch(
          shellControllerProvider.select(
            (state) => state.windowByObjectId(this.window.objectId),
          ),
        ) ??
        this.window;
    final liveGeometry = ref.watch(
      desktopWorkspaceProvider.select((state) {
        final placement = state.placements[this.placement.objectId];
        return placement == null
            ? null
            : (frameSize: placement.frame.size, dragging: placement.dragging);
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
    final placement = followsLivePlacement ? selectedPlacement : this.placement;
    final frame = followsLivePlacement
        ? desktopLivePlacementVisualFrame(
            visualFrame: this.frame,
            placementFrame: this.placement.frame,
            livePlacementFrame: placement.frame,
          )
        : this.frame;
    DesktopWindowRenderTelemetry.recordWindowBuild(
      windowId: window.objectId,
      textureId: window.textureId,
      label: window.appId.isEmpty
          ? localizedWindowTitle(context, window)
          : window.appId,
    );
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final transformed = overview || switching || desktopWidget;
    final duration = motionDuration;
    final fullscreenVisual = placement.fullscreen && !transformed;
    final drawsServerFrame = !fullscreenVisual && placement.serverSideDecorated;
    final theme = ShellTheme.of(context);
    final windowRadius = drawsServerFrame ? theme.windowRadius : 0.0;
    final windowOpacity = active
        ? theme.focusedWindowOpacity
        : theme.unfocusedWindowOpacity;
    final targetContentSize = drawsServerFrame
        ? frame.deflate(DesktopMetrics.frameBorder).size
        : frame.size;
    final resizing = desktopTextureNeedsResizeSmoothing(
      targetSize: targetContentSize,
      sourceSize: window.contentCoordinateRect.size,
    );
    return _DesktopAnimatedWindowPosition(
      duration: placement.dragging ? Duration.zero : duration,
      rect: frame,
      placementObjectId: placement.objectId,
      placementFrame: placement.frame,
      overview: overview,
      switching: switching,
      desktopWidget: desktopWidget,
      dragging: placement.dragging,
      child: DesktopWindowReveal(
        key: ValueKey<String>('desktop-window-content-${window.objectId}'),
        enabled: !window.suppressAnimations,
        child: IgnorePointer(
          ignoring: minimized || (desktopWidget && overviewActive),
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
                opacity: minimized
                    ? 0.0
                    : desktopWidget
                    ? 0.86 * windowOpacity
                    : windowOpacity,
                child: DesktopWindowRepaintBoundary(
                  outset: drawsServerFrame
                      ? DesktopWindowFramePainter.shadowOutset
                      : 0,
                  child: _DesktopOverviewPreviewInteraction(
                    overviewActive: overviewActive,
                    overview: overview,
                    desktopWidget: desktopWidget,
                    dragging: placement.dragging,
                    label: desktopWidget
                        ? context.l10n.desktopRestoreWindow(
                            localizedWindowTitle(context, window),
                          )
                        : context.l10n.desktopActivateWindow(
                            localizedWindowTitle(context, window),
                          ),
                    onTap: onOverviewTap,
                    onDragStart: onOverviewDragStart,
                    onDragUpdate: onOverviewDragUpdate,
                    onDragEnd: onOverviewDragEnd,
                    onDragCancel: onOverviewDragCancel,
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
                              child: _DesktopWindowContent(
                                window: window,
                                smooth:
                                    transformed ||
                                    resizing ||
                                    placement.dragging,
                                active: active && !minimized,
                                localLayoutSize: window.isLocalFlutter
                                    ? placement.contentRect.size
                                    : null,
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
                                ? theme.accentPalette.container
                                : active
                                ? theme.accent
                                : ShellColors.hairlineWindow,
                            devicePixelRatio: devicePixelRatio,
                            radius: windowRadius,
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
    );
  }
}

class _DesktopAnimatedWindowPosition extends ConsumerStatefulWidget {
  const _DesktopAnimatedWindowPosition({
    super.key,
    required this.duration,
    required this.rect,
    required this.placementObjectId,
    required this.placementFrame,
    required this.overview,
    required this.switching,
    this.desktopWidget = false,
    required this.dragging,
    required this.child,
  });

  final Duration duration;
  final Rect rect;
  final int placementObjectId;
  final Rect placementFrame;
  final bool overview;
  final bool switching;
  final bool desktopWidget;
  final bool dragging;
  final Widget child;

  @override
  ConsumerState<_DesktopAnimatedWindowPosition> createState() =>
      _DesktopAnimatedWindowPositionState();
}

class _DesktopAnimatedWindowPositionState
    extends ConsumerState<_DesktopAnimatedWindowPosition> {
  late Curve _curve;
  Rect? _dragAnchorRect;
  bool _overviewTransitionActive = false;
  bool _suppressNextPositionAnimation = false;

  @override
  void initState() {
    super.initState();
    _curve = widget.overview ? Motion.overviewEnterCurve : Motion.md3Emphasized;
    if (widget.dragging) {
      _dragAnchorRect = widget.rect;
    }
  }

  @override
  void didUpdateWidget(covariant _DesktopAnimatedWindowPosition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.dragging && widget.dragging) {
      _dragAnchorRect = widget.rect;
    } else if (oldWidget.dragging && !widget.dragging) {
      _dragAnchorRect = null;
      _suppressNextPositionAnimation = true;
    }
    final interruptedOverviewTransition = _overviewTransitionActive;
    if (!oldWidget.overview && widget.overview) {
      _curve = interruptedOverviewTransition
          ? Motion.overviewReversalCurve
          : Motion.overviewEnterCurve;
      _overviewTransitionActive = true;
    } else if (oldWidget.overview && !widget.overview) {
      _curve = interruptedOverviewTransition
          ? Motion.overviewReversalCurve
          : Motion.overviewExitCurve;
      _overviewTransitionActive = true;
    } else if (widget.desktopWidget != oldWidget.desktopWidget ||
        widget.switching ||
        oldWidget.switching) {
      _curve = Motion.md3Emphasized;
      _overviewTransitionActive = false;
    } else if (!_overviewTransitionActive &&
        !widget.overview &&
        widget.rect != oldWidget.rect) {
      _curve = Motion.standard;
    }
  }

  @override
  Widget build(BuildContext context) {
    final livePlacement = ref.watch(
      desktopWorkspaceProvider.select(
        (state) => state.placements[widget.placementObjectId],
      ),
    );
    var rect = widget.rect;
    final followsLivePlacement =
        widget.dragging && livePlacement?.dragging == true;
    if (followsLivePlacement) {
      rect = desktopLivePlacementVisualFrame(
        visualFrame: rect,
        placementFrame: widget.placementFrame,
        livePlacementFrame: livePlacement!.frame,
      );
    }
    final liveMove =
        followsLivePlacement &&
        livePlacement!.frame.size == widget.placementFrame.size;
    final dragAnchorRect = _dragAnchorRect;
    final translatesLiveMove =
        liveMove &&
        dragAnchorRect != null &&
        dragAnchorRect.width == rect.width &&
        dragAnchorRect.height == rect.height;
    final positionedRect = translatesLiveMove ? dragAnchorRect : rect;
    final translation = translatesLiveMove
        ? rect.topLeft - dragAnchorRect.topLeft
        : Offset.zero;
    final suppressPositionAnimation = _suppressNextPositionAnimation;
    _suppressNextPositionAnimation = false;
    return AnimatedPositioned.fromRect(
      duration: widget.dragging || suppressPositionAnimation
          ? Duration.zero
          : widget.duration,
      curve: _curve,
      rect: positionedRect,
      onEnd: () => _overviewTransitionActive = false,
      child: Transform.translate(offset: translation, child: widget.child),
    );
  }
}

class _DesktopOverviewPreviewInteraction extends StatefulWidget {
  const _DesktopOverviewPreviewInteraction({
    required this.overviewActive,
    required this.overview,
    required this.desktopWidget,
    required this.dragging,
    required this.label,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.child,
  });

  final bool overviewActive;
  final bool overview;
  final bool desktopWidget;
  final bool dragging;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  final Widget child;

  @override
  State<_DesktopOverviewPreviewInteraction> createState() =>
      _DesktopOverviewPreviewInteractionState();
}

class _DesktopOverviewPreviewInteractionState
    extends State<_DesktopOverviewPreviewInteraction> {
  static const double _hoverScale = 1.025;

  bool _hovered = false;

  @override
  void didUpdateWidget(covariant _DesktopOverviewPreviewInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.overview && !widget.desktopWidget) || widget.dragging) {
      _hovered = false;
    }
  }

  void _setHovered(bool hovered) {
    if ((!widget.overview && !widget.desktopWidget) || _hovered == hovered) {
      return;
    }
    setState(() => _hovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    final hovered =
        (widget.overview || widget.desktopWidget) &&
        !widget.dragging &&
        _hovered;
    final interactive =
        (widget.overviewActive && widget.overview) ||
        (!widget.overviewActive && widget.desktopWidget);
    return Semantics(
      button: interactive,
      label: interactive ? widget.label : null,
      child: MouseRegion(
        cursor: interactive ? ShellMouseCursors.link : ShellMouseCursors.normal,
        onEnter: interactive ? (_) => _setHovered(true) : null,
        onExit: interactive ? (_) => _setHovered(false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: interactive ? widget.onTap : null,
          onPanStart: widget.overview ? (_) => widget.onDragStart() : null,
          onPanUpdate: widget.overview
              ? (details) => widget.onDragUpdate(details.delta)
              : null,
          onPanEnd: widget.overview ? (_) => widget.onDragEnd() : null,
          onPanCancel: widget.overview ? widget.onDragCancel : null,
          child: AnimatedScale(
            duration: Motion.tile,
            curve: hovered
                ? Motion.md3EmphasizedDecelerate
                : Motion.md3EmphasizedAccelerate,
            scale: hovered
                ? widget.desktopWidget
                      ? 1.018
                      : _hoverScale
                : 1.0,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _DesktopSurfaceTexture extends StatefulWidget {
  const _DesktopSurfaceTexture({required this.window, required this.smooth});

  final DenialWindow window;
  final bool smooth;

  @override
  State<_DesktopSurfaceTexture> createState() => _DesktopSurfaceTextureState();
}

class _DesktopWindowContent extends ConsumerWidget {
  const _DesktopWindowContent({
    required this.window,
    required this.smooth,
    required this.active,
    this.localLayoutSize,
  });

  final DenialWindow window;
  final bool smooth;
  final bool active;
  final Size? localLayoutSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShellTheme.of(context);
    final windowOpacity = active
        ? theme.focusedWindowOpacity
        : theme.unfocusedWindowOpacity;
    final content = _buildContent();
    final localApplication = window.isLocalFlutter
        ? ref.watch(localFlutterApplicationRegistryProvider)[window.appId]
        : null;
    return ShellBackdropBlur(
      blur: desktopWindowBackdropBlurEnabled(
        window: window,
        shellOpacity: windowOpacity,
        opacityThreshold: theme.backdropBlurOpacityThreshold,
        localContentTranslucent: localApplication?.translucent ?? false,
      ),
      child: content,
    );
  }

  Widget _buildContent() {
    if (window.isLocalFlutter) {
      final host = LocalFlutterWindowHost(
        key: LocalFlutterWindowHostKey(window.objectId),
        window: window,
        active: active,
      );
      final layoutSize = localLayoutSize;
      if (layoutSize == null || layoutSize.isEmpty) {
        return host;
      }
      // Native clients keep their configured buffer size while overview,
      // switching, and minimize animate the compositor texture. Give local
      // Flutter apps the same contract: retain the real window layout and
      // scale the complete app as one surface for shell-only transitions.
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.fill,
          clipBehavior: Clip.hardEdge,
          child: SizedBox.fromSize(size: layoutSize, child: host),
        ),
      );
    }
    return _DesktopSurfaceTexture(window: window, smooth: smooth);
  }
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
    final filterQuality = _smooth ? FilterQuality.medium : FilterQuality.none;
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
    required this.radius,
  });

  final int windowId;
  final Color color;
  final double devicePixelRatio;
  final double radius;

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
    final resolvedRadius = math.max(0.0, radius - inset);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = pixel
      ..isAntiAlias = false;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(resolvedRadius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _DesktopWindowBorderPainter oldDelegate) {
    return windowId != oldDelegate.windowId ||
        color != oldDelegate.color ||
        devicePixelRatio != oldDelegate.devicePixelRatio ||
        radius != oldDelegate.radius;
  }
}

class _DesktopDashboard extends ConsumerWidget {
  const _DesktopDashboard({
    required this.onEnter,
    required this.onExit,
    required this.onOpenWallpaper,
    required this.onOpenAppVolumeManager,
    required this.onOpenSettings,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onOpenWallpaper;
  final VoidCallback onOpenAppVolumeManager;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quickSettings = ref.watch(quickSettingsProvider);
    final quickSettingsController = ref.read(quickSettingsProvider.notifier);
    final bluetooth = ref.watch(bluetoothProvider);
    final bluetoothController = ref.read(bluetoothProvider.notifier);
    final notifications = ref.watch(desktopNotificationsProvider);
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;

    void openNotifications() {
      ref
          .read(shellSurfaceControllerProvider.notifier)
          .show(
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
            color: theme.panelColor(ShellColors.panelBackground),
            borderRadius: BorderRadius.circular(theme.panelRadius),
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
                        l10n.desktopDashboardTitle,
                        style: ShellText.statusClock.copyWith(fontSize: 22),
                      ),
                    ),
                    _DashboardIconButton(
                      semanticLabel: notifications.unreadCount == 0
                          ? l10n.desktopOpenNotificationCenter
                          : l10n.desktopOpenNotificationCenterUnread(
                              notifications.unreadCount,
                            ),
                      icon: notifications.unreadCount == 0
                          ? Icons.notifications_none_rounded
                          : Icons.notifications_active_rounded,
                      active: notifications.unreadCount > 0,
                      onTap: openNotifications,
                    ),
                    const SizedBox(width: 7),
                    _DashboardIconButton(
                      semanticLabel: l10n.settingsApplicationSemanticsLabel,
                      icon: Icons.settings_rounded,
                      onTap: onOpenSettings,
                    ),
                    const SizedBox(width: 7),
                    _DashboardIconButton(
                      semanticLabel: l10n.desktopOpenPowerControls,
                      icon: Icons.power_settings_new_rounded,
                      onTap: () => showPowerSessionSurface(ref),
                    ),
                    const SizedBox(width: 7),
                    _DashboardIconButton(
                      semanticLabel: l10n.desktopChooseWallpaper,
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
                          Icon(
                            Icons.volume_up_rounded,
                            size: 21,
                            color: theme.accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              l10n.commonVolume,
                              style: ShellText.cardTitle,
                            ),
                          ),
                          _DashboardValueButton(
                            semanticLabel: l10n.desktopOpenApplicationAudio,
                            label: l10n.settingsPercent(
                              (quickSettings.volume * 100).round(),
                            ),
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
                        activeColor: theme.accent,
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
                Expanded(
                  child: _DashboardCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.bluetooth_rounded,
                              size: 21,
                              color: theme.accent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                l10n.commonBluetooth,
                                style: ShellText.cardTitle,
                              ),
                            ),
                            _DashboardIconButton(
                              semanticLabel: bluetooth.powered
                                  ? l10n.desktopTurnBluetoothOff
                                  : l10n.desktopTurnBluetoothOn,
                              icon: Icons.power_settings_new_rounded,
                              active: bluetooth.powered,
                              busy: bluetooth.powerChanging,
                              onTap: bluetoothController.togglePower,
                            ),
                            const SizedBox(width: 7),
                            _DashboardIconButton(
                              semanticLabel: l10n.desktopScanBluetooth,
                              icon: Icons.bluetooth_searching_rounded,
                              active:
                                  bluetooth.scanning || bluetooth.discovering,
                              busy: bluetooth.scanning,
                              enabled: bluetooth.powered,
                              onTap: bluetoothController.scan,
                            ),
                            const SizedBox(width: 7),
                            _DashboardIconButton(
                              semanticLabel: l10n.desktopRefreshBluetooth,
                              icon: Icons.refresh_rounded,
                              busy: bluetooth.refreshing,
                              onTap: bluetoothController.refresh,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (bluetooth.error != null) ...[
                          Text(
                            l10n.settingsBluetoothUnavailable,
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
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    return MainOutputCenteredSurface(
      builder: (context, constraints) {
        final panelWidth = math.min(520.0, constraints.maxWidth);
        final panelHeight = math.min(720.0, constraints.maxHeight);
        return SizedBox(
          width: panelWidth,
          height: panelHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.panelColor(ShellColors.panelBackground),
              borderRadius: BorderRadius.circular(theme.panelRadius),
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
                          l10n.notificationsTitle,
                          style: ShellText.statusClock.copyWith(fontSize: 22),
                        ),
                      ),
                      _DashboardIconButton(
                        semanticLabel: l10n.notificationsCloseCenter,
                        icon: Icons.close_rounded,
                        onTap: handle.close,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Expanded(child: NotificationCenter(showTitle: false)),
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
      child: Padding(padding: const EdgeInsets.all(16), child: child),
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
    final gpuEnabled = modes.gpuAvailable && !modes.gpuChanging;
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;

    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 21, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.desktopPowerModesTitle,
                  style: ShellText.cardTitle,
                ),
              ),
              _DashboardIconButton(
                semanticLabel: l10n.desktopRefreshPowerModes,
                icon: Icons.refresh_rounded,
                busy: modes.refreshing,
                enabled:
                    !modes.systemChanging &&
                    !modes.pboChanging &&
                    !modes.gpuChanging,
                onTap: () => unawaited(controller.refresh()),
              ),
            ],
          ),
          const SizedBox(height: 11),
          _PowerModeRow(
            label: l10n.desktopSystemProfile,
            available: modes.systemAvailable,
            checking: modes.refreshing,
            children: [
              _PowerModeOption(
                semanticLabel: l10n.desktopSystemProfilePowerSaver,
                icon: Icons.energy_savings_leaf_rounded,
                selected: modes.systemProfile == PowerProfile.powerSave,
                busy:
                    modes.systemChanging &&
                    modes.systemProfile == PowerProfile.powerSave,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.powerSave),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopSystemProfileBalanced,
                icon: Icons.balance_rounded,
                selected: modes.systemProfile == PowerProfile.balanced,
                busy:
                    modes.systemChanging &&
                    modes.systemProfile == PowerProfile.balanced,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.balanced),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopSystemProfilePerformance,
                icon: Icons.rocket_launch_rounded,
                selected: modes.systemProfile == PowerProfile.performance,
                busy:
                    modes.systemChanging &&
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
            label: l10n.desktopPboLabel,
            available: modes.pboAvailable,
            checking: modes.refreshing,
            children: [
              _PowerModeOption(
                semanticLabel: l10n.desktopPboSilent,
                icon: Icons.bedtime_rounded,
                selected: modes.pboProfile == DesktopPboProfile.silent,
                busy:
                    modes.pboChanging &&
                    modes.pboProfile == DesktopPboProfile.silent,
                enabled: pboEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectPboProfile(DesktopPboProfile.silent),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopPboBalanced,
                icon: Icons.balance_rounded,
                selected: modes.pboProfile == DesktopPboProfile.balanced,
                busy:
                    modes.pboChanging &&
                    modes.pboProfile == DesktopPboProfile.balanced,
                enabled: pboEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectPboProfile(DesktopPboProfile.balanced),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopPboPerformance,
                icon: Icons.speed_rounded,
                selected: modes.pboProfile == DesktopPboProfile.performance,
                busy:
                    modes.pboChanging &&
                    modes.pboProfile == DesktopPboProfile.performance,
                enabled: pboEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectPboProfile(DesktopPboProfile.performance),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _PowerModeRow(
            label: l10n.desktopGpuLabel,
            available: modes.gpuAvailable,
            checking: modes.refreshing,
            children: [
              _PowerModeOption(
                semanticLabel: l10n.desktopGpuPresetLow,
                icon: Icons.keyboard_double_arrow_down_rounded,
                selected:
                    modes.gpuPerformancePreset == LactPerformancePreset.low,
                busy:
                    modes.gpuChanging &&
                    modes.gpuPerformancePreset == LactPerformancePreset.low,
                enabled: gpuEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectGpuPerformancePreset(
                    LactPerformancePreset.low,
                  ),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopGpuPresetAutomatic,
                icon: Icons.auto_mode_rounded,
                selected:
                    modes.gpuPerformancePreset ==
                    LactPerformancePreset.automatic,
                busy:
                    modes.gpuChanging &&
                    modes.gpuPerformancePreset ==
                        LactPerformancePreset.automatic,
                enabled: gpuEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectGpuPerformancePreset(
                    LactPerformancePreset.automatic,
                  ),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopGpuPresetHigh,
                icon: Icons.keyboard_double_arrow_up_rounded,
                selected:
                    modes.gpuPerformancePreset == LactPerformancePreset.high,
                busy:
                    modes.gpuChanging &&
                    modes.gpuPerformancePreset == LactPerformancePreset.high,
                enabled: gpuEnabled,
                secondary: true,
                onTap: () => unawaited(
                  controller.selectGpuPerformancePreset(
                    LactPerformancePreset.high,
                  ),
                ),
              ),
            ],
          ),
          if (modes.error != null) ...[
            const SizedBox(height: 9),
            Text(
              l10n.desktopPowerModesUnavailable,
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
    final l10n = context.l10n;
    final availability = checking && !available
        ? l10n.commonChecking
        : available
        ? null
        : l10n.commonUnavailable;
    return Row(
      children: [
        Expanded(
          child: Text(
            availability == null
                ? label
                : l10n.desktopFeatureAvailability(label, availability),
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
    final accent = ShellTheme.of(context).accentPalette;
    final selectedBackground = widget.secondary
        ? accent.mutedContainer
        : accent.container;
    final selectedForeground = widget.secondary
        ? accent.onMutedContainer
        : accent.onContainer;

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
                  ? Border.all(color: accent.primary, width: 1.5)
                  : null,
            ),
            child: widget.busy
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent.primary,
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
    final l10n = context.l10n;
    if (state.refreshing && state.devices.isEmpty) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: ShellTheme.of(context).accent,
          ),
        ),
      );
    }
    if (!state.available) {
      return _DashboardEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        label: l10n.settingsBluetoothUnavailable,
      );
    }
    if (!state.powered) {
      return _DashboardEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        label: l10n.desktopEnableBluetoothForDevices,
      );
    }
    if (state.devices.isEmpty) {
      return _DashboardEmptyState(
        icon: state.scanning
            ? Icons.bluetooth_searching_rounded
            : Icons.bluetooth_rounded,
        label: state.scanning
            ? l10n.desktopScanningBluetoothDevices
            : l10n.settingsNoBluetoothDevices,
      );
    }

    return ListView.separated(
      itemCount: state.devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
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
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    final status = device.connected
        ? l10n.settingsConnected
        : device.paired
        ? l10n.settingsPaired
        : l10n.settingsAvailable;
    return Semantics(
      button: true,
      label: device.connected
          ? l10n.desktopDisconnectDevice(device.name)
          : l10n.desktopConnectDevice(device.name),
      child: MouseRegion(
        cursor: widget.busy
            ? ShellMouseCursors.working
            : ShellMouseCursors.link,
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
                  ? accent.container
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
                      ? accent.onContainer
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
                              ? accent.onContainerSecondary
                              : ShellColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.busy)
                  SizedBox(
                    width: 21,
                    height: 21,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent.primary,
                    ),
                  )
                else
                  Icon(
                    device.connected ? Icons.link_off_rounded : Icons.link,
                    size: 20,
                    color: device.connected
                        ? accent.onContainer
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
    final accent = ShellTheme.of(context).accentPalette;
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
                  ? accent.container
                  : _hovered
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: widget.busy
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent.primary,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 18,
                    color: widget.enabled
                        ? widget.active
                              ? accent.onContainer
                              : ShellColors.textPrimary
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
    final accent = ShellTheme.of(context).accentPalette;
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
                color: _focused ? accent.primary : ShellColors.hairlineSoft,
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
                Icon(widget.icon, size: 16, color: accent.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
class _DesktopLauncherEntry {
  const _DesktopLauncherEntry._({
    required this.id,
    required this.name,
    required this.categories,
    required this.iconPath,
    required this.icon,
    required this.desktopApp,
    required this.localApp,
  });

  factory _DesktopLauncherEntry.desktop(DesktopApp app) {
    return _DesktopLauncherEntry._(
      id: app.id,
      name: app.name,
      categories: app.categories,
      iconPath: app.iconPath,
      icon: null,
      desktopApp: app,
      localApp: null,
    );
  }

  factory _DesktopLauncherEntry.local(
    LocalFlutterApplication app,
    BuildContext context,
  ) {
    return _DesktopLauncherEntry._(
      id: app.id,
      name: app.titleFor(context),
      categories: app.categoriesFor(context),
      iconPath: null,
      icon: app.icon,
      desktopApp: null,
      localApp: app,
    );
  }

  final String id;
  final String name;
  final List<String> categories;
  final String? iconPath;
  final IconData? icon;
  final DesktopApp? desktopApp;
  final LocalFlutterApplication? localApp;
}

class DesktopApplicationLauncher extends ConsumerStatefulWidget {
  const DesktopApplicationLauncher({
    super.key,
    required this.searchFocusNode,
    required this.onEnter,
    required this.onExit,
    required this.onLaunch,
    required this.onLaunchLocal,
  });

  final FocusNode searchFocusNode;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final ValueChanged<DesktopApp> onLaunch;
  final ValueChanged<LocalFlutterApplication> onLaunchLocal;

  @override
  ConsumerState<DesktopApplicationLauncher> createState() =>
      _DesktopApplicationLauncherState();
}

class _DesktopApplicationLauncherState
    extends ConsumerState<DesktopApplicationLauncher> {
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

  void _launch(_DesktopLauncherEntry entry) {
    final desktopApp = entry.desktopApp;
    if (desktopApp != null) {
      widget.onLaunch(desktopApp);
      return;
    }
    widget.onLaunchLocal(entry.localApp!);
  }

  @override
  Widget build(BuildContext context) {
    final allApps = _installedApps(
      context,
      ref.watch(homeGridControllerProvider),
      ref.watch(localFlutterApplicationRegistryProvider).applications,
    );
    final apps = _filterInstalledApps(allApps, _searchController.text);
    final searching = _searchController.text.trim().isNotEmpty;
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    return MouseRegion(
      onEnter: (_) => widget.onEnter(),
      onExit: (_) => widget.onExit(),
      child: FocusTraversalGroup(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.panelColor(ShellColors.panelBackground),
            borderRadius: BorderRadius.circular(theme.panelRadius),
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
                  l10n.desktopApplicationsTitle,
                  style: ShellText.statusClock.copyWith(fontSize: 22),
                ),
                const SizedBox(height: 4),
                Text(
                  searching
                      ? l10n.desktopApplicationSearchResults(
                          apps.length,
                          allApps.length,
                        )
                      : l10n.desktopInstalledApplications(allApps.length),
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
                      _launch(apps.first);
                    }
                  },
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: allApps.isEmpty
                      ? Center(child: Text(l10n.desktopLoadingApplications))
                      : apps.isEmpty
                      ? const _DesktopAppSearchEmptyState()
                      : GridView.builder(
                          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 112,
                                mainAxisExtent: 112,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: apps.length,
                          itemBuilder: (context, index) => _DesktopAppTile(
                            key: ValueKey<String>(
                              'desktop-app-${apps[index].id}',
                            ),
                            app: apps[index],
                            selected: searching && index == 0,
                            onTap: () => _launch(apps[index]),
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
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    return Semantics(
      textField: true,
      label: l10n.desktopSearchApplications,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          border: Border.all(
            color: focusNode.hasFocus ? accent.primary : ShellColors.hairline,
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
                        IgnorePointer(
                          child: Text(
                            l10n.desktopSearchApplications,
                            style: const TextStyle(
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
                        cursorColor: accent.primary,
                        backgroundCursorColor: ShellColors.textSecondary,
                        selectionColor: accent.selection,
                      ),
                    ],
                  ),
                ),
                if (hasQuery) ...[
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: l10n.desktopClearApplicationSearch,
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
            context.l10n.desktopNoApplicationsFound,
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
    super.key,
    required this.app,
    required this.selected,
    required this.onTap,
  });

  final _DesktopLauncherEntry app;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DesktopAppTile> createState() => _DesktopAppTileState();
}

class _DesktopAppTileState extends State<_DesktopAppTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: l10n.desktopLaunchApplication(widget.app.name),
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
                  ? accent.container
                  : _hovered
                  ? ShellColors.surfaceContainerHighest
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(18),
              border: widget.selected
                  ? Border.all(color: accent.primary)
                  : null,
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 54,
                  height: 54,
                  child: widget.app.icon != null
                      ? ExcludeSemantics(
                          child: Icon(
                            widget.app.icon!,
                            size: 46,
                            color: accent.primary,
                          ),
                        )
                      : DeferredAppIcon(iconPath: widget.app.iconPath),
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

List<_DesktopLauncherEntry> _installedApps(
  BuildContext context,
  AsyncValue<HomeGridState> state,
  Iterable<LocalFlutterApplication> localApps,
) {
  final byId = <String, _DesktopLauncherEntry>{};
  for (final item
      in state.asData?.value.slots.whereType<HomeGridItem>() ??
          const <HomeGridItem>[]) {
    if (item.app case final app?) {
      byId['desktop:${app.id}'] = _DesktopLauncherEntry.desktop(app);
    }
  }
  for (final app in localApps) {
    byId['local:${app.id}'] = _DesktopLauncherEntry.local(app, context);
  }
  final apps = byId.values.toList(growable: false)
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return apps;
}

List<_DesktopLauncherEntry> _filterInstalledApps(
  List<_DesktopLauncherEntry> apps,
  String query,
) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) {
    return apps;
  }

  return apps
      .where((app) {
        final searchable = <String>[
          app.name,
          app.id,
          ...app.categories,
        ].join(' ').toLowerCase();
        return searchable.contains(normalizedQuery);
      })
      .toList(growable: false);
}
