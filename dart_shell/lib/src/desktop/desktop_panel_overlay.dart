part of 'desktop_shell.dart';

class _DesktopPanelOverlay extends ConsumerStatefulWidget {
  const _DesktopPanelOverlay({
    required this.viewSize,
    required this.shellOutputRect,
    required this.panelTravel,
    required this.panelDurationScale,
    required this.applicationSearchFocusNode,
    required this.onOpenLauncher,
    required this.onDismissLauncher,
    required this.onOpenDashboard,
    required this.onOpenWallpaperSelector,
    required this.onOpenAppVolumeManager,
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
  final VoidCallback onDismissLauncher;
  final VoidCallback onOpenDashboard;
  final VoidCallback onOpenWallpaperSelector;
  final VoidCallback onOpenAppVolumeManager;
  final VoidCallback onOpenSettings;
  final VoidCallback onCancelPanelClose;
  final VoidCallback onSchedulePanelClose;
  final VoidCallback onPanelOpened;
  final ValueChanged<DesktopApp> onLaunchApp;
  final ValueChanged<LocalFlutterApplication> onLaunchLocalApp;

  @override
  ConsumerState<_DesktopPanelOverlay> createState() =>
      _DesktopPanelOverlayState();
}

class _DesktopPanelOverlayState extends ConsumerState<_DesktopPanelOverlay> {
  DesktopApplicationLauncher? _applicationLauncher;
  _DesktopDashboard? _dashboard;

  DesktopApplicationLauncher _cachedApplicationLauncher() {
    final cached = _applicationLauncher;
    if (cached != null &&
        identical(cached.searchFocusNode, widget.applicationSearchFocusNode) &&
        cached.onEnter == widget.onCancelPanelClose &&
        cached.onExit == widget.onSchedulePanelClose &&
        cached.onDismiss == widget.onDismissLauncher &&
        cached.onLaunch == widget.onLaunchApp &&
        cached.onLaunchLocal == widget.onLaunchLocalApp) {
      return cached;
    }
    return _applicationLauncher = DesktopApplicationLauncher(
      searchFocusNode: widget.applicationSearchFocusNode,
      onEnter: widget.onCancelPanelClose,
      onExit: widget.onSchedulePanelClose,
      onDismiss: widget.onDismissLauncher,
      onLaunch: widget.onLaunchApp,
      onLaunchLocal: widget.onLaunchLocalApp,
    );
  }

  _DesktopDashboard _cachedDashboard() {
    final cached = _dashboard;
    if (cached != null &&
        cached.onEnter == widget.onCancelPanelClose &&
        cached.onExit == widget.onSchedulePanelClose &&
        cached.onOpenWallpaper == widget.onOpenWallpaperSelector &&
        cached.onOpenAppVolumeManager == widget.onOpenAppVolumeManager &&
        cached.onOpenSettings == widget.onOpenSettings) {
      return cached;
    }
    return _dashboard = _DesktopDashboard(
      onEnter: widget.onCancelPanelClose,
      onExit: widget.onSchedulePanelClose,
      onOpenWallpaper: widget.onOpenWallpaperSelector,
      onOpenAppVolumeManager: widget.onOpenAppVolumeManager,
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
    final dashboardTriggerRect = DesktopMetrics.dashboardTriggerRect(
      widget.viewSize,
      outputRect: widget.shellOutputRect,
      placement: overlaySettings.dashboard,
    );
    final launcherOpen = panelState.panel == DesktopPanel.launcher;
    final dashboardOpen = panelState.panel == DesktopPanel.dashboard;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          key: const ValueKey<String>('desktop-launcher-dismiss-barrier'),
          child: ShellInputRegion(
            debugLabel: 'Desktop launcher dismiss barrier',
            active: launcherOpen,
            pointerPolicy: ShellPointerPolicy.fullScene,
            keyboardPolicy: ShellKeyboardPolicy.none,
            child: IgnorePointer(
              ignoring: !launcherOpen,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDismissLauncher,
              ),
            ),
          ),
        ),
        if (!launcherRect.isEmpty)
          Positioned.fromRect(
            key: const ValueKey<String>('desktop-launcher-position'),
            rect: launcherRect,
            child: DesktopPanelTransition(
              key: const ValueKey<String>('desktop-launcher-panel'),
              inputDebugLabel: 'Desktop application launcher',
              keyboardPolicy: ShellKeyboardPolicy.capture,
              maintainState: true,
              visible: launcherOpen,
              entryDirection: _entryDirectionFor(
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
              entryDirection: _entryDirectionFor(
                overlaySettings.dashboard.anchor.horizontal,
                overlaySettings.dashboard.anchor.vertical,
              ),
              entryDistance: widget.panelTravel,
              durationScale: widget.panelDurationScale,
              onOpened: widget.onPanelOpened,
              child: _cachedDashboard(),
            ),
          ),
        if (!panelState.overviewActive && !launcherTriggerRect.isEmpty)
          Positioned.fromRect(
            rect: launcherTriggerRect,
            child: ShellInputRegion(
              debugLabel: 'Desktop launcher edge trigger',
              child: _DesktopPanelEdgeTrigger(
                onEnter: widget.onOpenLauncher,
                onExit: widget.onSchedulePanelClose,
              ),
            ),
          ),
        if (!panelState.overviewActive && !dashboardTriggerRect.isEmpty)
          Positioned.fromRect(
            rect: dashboardTriggerRect,
            child: ShellInputRegion(
              debugLabel: 'Desktop dashboard edge trigger',
              child: _DesktopPanelEdgeTrigger(
                onEnter: widget.onOpenDashboard,
                onExit: widget.onSchedulePanelClose,
              ),
            ),
          ),
      ],
    );
  }
}
