import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/default_shell/panel_composition.dart';
import 'desktop_application_launcher.dart';
import 'desktop_dashboard.dart';
import 'desktop_panel_edges.dart';
import 'desktop_panel_transition.dart';
import 'desktop_workspace.dart';

class DesktopPanelOverlay extends ConsumerStatefulWidget {
  const DesktopPanelOverlay({
    super.key,
    required this.viewSize,
    required this.shellOutputRect,
    required this.panelTravel,
    required this.panelDurationScale,
    required this.applicationSearchFocusNode,
    required this.onOpenLauncher,
    required this.onDismissPanel,
    required this.onOpenDashboard,
    required this.onOpenSettings,
    required this.onCancelPanelClose,
    required this.onSchedulePanelClose,
    required this.onPanelOpened,
    required this.onLaunchApp,
    required this.onLaunchLocalApp,
  });

  final Size viewSize;
  final Rect? shellOutputRect;
  final double panelTravel;
  final double panelDurationScale;
  final FocusNode applicationSearchFocusNode;
  final VoidCallback onOpenLauncher;
  final VoidCallback onDismissPanel;
  final VoidCallback onOpenDashboard;
  final VoidCallback onOpenSettings;
  final VoidCallback onCancelPanelClose;
  final VoidCallback onSchedulePanelClose;
  final VoidCallback onPanelOpened;
  final ValueChanged<DesktopApp> onLaunchApp;
  final ValueChanged<LocalFlutterApplication> onLaunchLocalApp;

  @override
  ConsumerState<DesktopPanelOverlay> createState() =>
      _DesktopPanelOverlayState();
}

class _DesktopPanelOverlayState extends ConsumerState<DesktopPanelOverlay> {
  DesktopApplicationLauncher? _applicationLauncher;
  DesktopDashboard? _dashboard;

  DesktopApplicationLauncher _cachedApplicationLauncher() {
    final cached = _applicationLauncher;
    if (cached != null &&
        identical(cached.searchFocusNode, widget.applicationSearchFocusNode) &&
        cached.onEnter == widget.onCancelPanelClose &&
        cached.onExit == widget.onSchedulePanelClose &&
        cached.onDismiss == widget.onDismissPanel &&
        cached.onLaunch == widget.onLaunchApp &&
        cached.onLaunchLocal == widget.onLaunchLocalApp) {
      return cached;
    }
    return _applicationLauncher = DesktopApplicationLauncher(
      searchFocusNode: widget.applicationSearchFocusNode,
      onEnter: widget.onCancelPanelClose,
      onExit: widget.onSchedulePanelClose,
      onDismiss: widget.onDismissPanel,
      onLaunch: widget.onLaunchApp,
      onLaunchLocal: widget.onLaunchLocalApp,
    );
  }

  DesktopDashboard _cachedDashboard() {
    final cached = _dashboard;
    if (cached != null &&
        cached.onEnter == widget.onCancelPanelClose &&
        cached.onExit == widget.onSchedulePanelClose &&
        cached.onOpenSettings == widget.onOpenSettings) {
      return cached;
    }
    return _dashboard = DesktopDashboard(
      onEnter: widget.onCancelPanelClose,
      onExit: widget.onSchedulePanelClose,
      onOpenSettings: widget.onOpenSettings,
    );
  }

  @override
  Widget build(BuildContext context) {
    final panelState = ref.watch(
      desktopWorkspaceProvider.select(
        (state) => (panel: state.panel, overviewActive: state.overviewActive),
      ),
    );
    final overlaySettings = ref.watch(
      shellSettingsProvider.select((settings) => settings.overlays),
    );
    final launcherRect = DesktopMetrics.launcherRect(
      widget.viewSize,
      outputRect: widget.shellOutputRect,
      placement: overlaySettings.launcher,
    );
    final dashboardRect = DesktopMetrics.dashboardRect(
      widget.viewSize,
      outputRect: widget.shellOutputRect,
      placement: overlaySettings.dashboard,
    );
    final launcherTriggerRect = DesktopMetrics.launcherTriggerRect(
      widget.viewSize,
      outputRect: widget.shellOutputRect,
      placement: overlaySettings.launcher,
    );
    final launcherSwipe = DesktopMetrics.launcherSwipeEdge(
      widget.viewSize,
      outputRect: widget.shellOutputRect,
      placement: overlaySettings.launcher,
    );
    final dashboardTriggerRect = DesktopMetrics.dashboardTriggerRect(
      widget.viewSize,
      outputRect: widget.shellOutputRect,
      placement: overlaySettings.dashboard,
    );
    final hasLauncher = ref.watch(desktopLauncherProvider) != null;
    final launcherOpen =
        hasLauncher && panelState.panel == DesktopPanel.launcher;
    final dashboardOpen = panelState.panel == DesktopPanel.dashboard;
    final panelOpen = launcherOpen || dashboardOpen;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          key: const ValueKey<String>('desktop-panel-dismiss-barrier'),
          child: ShellInputRegion(
            debugLabel: 'Desktop panel dismiss barrier',
            active: panelOpen,
            pointerPolicy: ShellPointerPolicy.fullScene,
            keyboardPolicy: ShellKeyboardPolicy.none,
            child: IgnorePointer(
              ignoring: !panelOpen,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDismissPanel,
              ),
            ),
          ),
        ),
        if (hasLauncher && !launcherRect.isEmpty)
          Positioned.fromRect(
            key: const ValueKey<String>('desktop-launcher-position'),
            rect: launcherRect,
            child: DesktopPanelTransition(
              key: const ValueKey<String>('desktop-launcher-panel'),
              inputDebugLabel: 'Desktop application launcher',
              keyboardPolicy: ShellKeyboardPolicy.capture,
              maintainState: true,
              visible: launcherOpen,
              entryDirection: desktopPanelEntryDirection(
                overlaySettings.launcher.anchor.horizontal,
                overlaySettings.launcher.anchor.vertical,
              ),
              entryDistance: widget.panelTravel,
              durationScale: widget.panelDurationScale,
              onOpened: widget.onPanelOpened,
              child: _cachedApplicationLauncher(),
            ),
          ),
        if (!dashboardRect.isEmpty)
          Positioned.fromRect(
            key: const ValueKey<String>('desktop-dashboard-position'),
            rect: dashboardRect,
            child: DesktopPanelTransition(
              key: const ValueKey<String>('desktop-dashboard-panel'),
              inputDebugLabel: 'Desktop dashboard',
              keyboardPolicy: ShellKeyboardPolicy.capture,
              maintainState: true,
              visible: dashboardOpen,
              entryDirection: desktopPanelEntryDirection(
                overlaySettings.dashboard.anchor.horizontal,
                overlaySettings.dashboard.anchor.vertical,
              ),
              entryDistance: widget.panelTravel,
              durationScale: widget.panelDurationScale,
              onOpened: widget.onPanelOpened,
              child: _cachedDashboard(),
            ),
          ),
        if (hasLauncher &&
            !panelState.overviewActive &&
            !launcherTriggerRect.isEmpty)
          Positioned.fromRect(
            rect: launcherTriggerRect,
            child: ShellInputRegion(
              debugLabel: 'Desktop launcher edge trigger',
              child: DesktopPanelEdgeTrigger(
                onEnter: widget.onOpenLauncher,
                onExit: widget.onSchedulePanelClose,
              ),
            ),
          ),
        // Above the hover trigger: a finger has no hover. The compositor
        // hands a swipe over a window to the shell once it moves inward.
        if (hasLauncher && !panelState.overviewActive)
          if (launcherSwipe case final swipe?)
            Positioned.fromRect(
              rect: swipe.rect,
              child: DesktopPanelEdgeSwipe(
                edge: swipe.edge,
                onSwipe: widget.onOpenLauncher,
              ),
            ),
        if (!panelState.overviewActive && !dashboardTriggerRect.isEmpty)
          Positioned.fromRect(
            rect: dashboardTriggerRect,
            child: ShellInputRegion(
              debugLabel: 'Desktop dashboard edge trigger',
              child: DesktopPanelEdgeTrigger(
                onEnter: widget.onOpenDashboard,
                onExit: widget.onSchedulePanelClose,
              ),
            ),
          ),
      ],
    );
  }
}
