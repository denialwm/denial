import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop/desktop_input_layout_publisher.dart';
import 'desktop/desktop_shell.dart';
import 'input/input_layout.dart';
import 'launcher/home_surface.dart';
import 'localization/denial_localizations.dart';
import 'models/denial_window.dart';
import 'settings/settings_controller.dart';
import 'settings/shell_settings.dart';
import 'state/cursor_theme.dart';
import 'state/bluetooth.dart';
import 'state/desktop_notifications.dart';
import 'state/display_layout.dart';
import 'state/shell_controller.dart';
import 'state/shell_profile.dart';
import 'state/screenshot_selection.dart';
import 'theme/cursor_themes.dart';
import 'theme/motion.dart';
import 'theme/shell_theme.dart';
import 'theme/tokens.dart';
import 'wallpaper/state/wallpaper_accent.dart';
import 'widgets/bottom_gesture_handle.dart';
import 'widgets/connectivity/bluetooth_detail_surface.dart';
import 'widgets/edge_panel_layer.dart';
import 'widgets/input_layout_publisher.dart';
import 'widgets/launch_transition_layer.dart';
import 'widgets/lock/lock_screen_layer.dart';
import 'widgets/notification_banner.dart';
import 'widgets/overview/overview_layer.dart';
import 'widgets/shade/system_shade_layer.dart';
import 'widgets/shell_cursor.dart';
import 'widgets/shell_frame_time_overlay.dart';
import 'widgets/screenshot_selection_layer.dart';
import 'widgets/shell_surface_host.dart';
import 'widgets/shell_wallpaper.dart';
import 'widgets/system_level_hud.dart';
import 'widgets/window_texture_rect.dart';

const _shellDragDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.mouse,
  PointerDeviceKind.unknown,
};

class _ShellScrollBehavior extends ScrollBehavior {
  const _ShellScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => _shellDragDevices;
}

final _userAppWindowsProvider = Provider<List<DenialWindow>>((ref) {
  final windows = ref.watch(
    shellControllerProvider.select((state) => state.windows),
  );
  return List<DenialWindow>.unmodifiable(
    windows.where((window) => window.isUserApp),
  );
});

class DenialShellApp extends ConsumerStatefulWidget {
  const DenialShellApp({super.key});

  @override
  ConsumerState<DenialShellApp> createState() => _DenialShellAppState();
}

class _DenialShellAppState extends ConsumerState<DenialShellApp> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(
      shellSettingsProvider.select((settings) => settings.layout),
      (_, layout) => _scheduleLayoutSync(layout),
      fireImmediately: true,
    );
    ref.listenManual(
      shellSettingsProvider.select((settings) => settings.power),
      (_, power) => _schedulePowerSync(power),
      fireImmediately: true,
    );
  }

  void _scheduleLayoutSync(ShellLayoutSettings layout) {
    // A manual listener gives the compositor its persisted policy on the very
    // first frame. Deferring the cross-provider mutation also keeps it outside
    // Flutter's widget lifecycle callbacks.
    scheduleMicrotask(() {
      if (!mounted) {
        return;
      }
      ref
          .read(displayLayoutProvider.notifier)
          .applyShellConfiguration(
            side: layout.systemBarSide,
            outputNames: layout.systemBarOutputNames,
            systemBarThickness: layout.systemBarThickness,
            maximizePadding: layout.maximizePadding,
          );
    });
  }

  void _schedulePowerSync(ShellPowerSettings power) {
    scheduleMicrotask(() {
      if (!mounted) {
        return;
      }
      ref
          .read(denialBridgeProvider)
          .setIdleDpmsTimeout(
            power.idleDpmsEnabled
                ? Duration(minutes: power.idleDpmsTimeoutMinutes)
                : null,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    // These providers own process-lifetime integrations. Keeping this explicit
    // root subscription documents and enforces their eager initialization.
    ref.watch(shellControllerProvider.select((_) => null));
    ref.watch(desktopNotificationsProvider.select((_) => null));
    ref.listen<bool>(
      shellControllerProvider.select((state) => state.lockLayerVisible),
      (_, lockLayerVisible) {
        if (lockLayerVisible) {
          ref
              .read(shellSurfaceControllerProvider.notifier)
              .dismissAllImmediately();
        }
      },
    );
    ref.listen<int?>(
      bluetoothProvider.select((state) => state.pairingRequest?.id),
      (_, requestId) {
        if (requestId == null) {
          return;
        }
        if (ref.read(shellControllerProvider).lockLayerVisible) {
          ref
              .read(bluetoothProvider.notifier)
              .respondToPairing(accepted: false);
          return;
        }
        ref
            .read(shellSurfaceControllerProvider.notifier)
            .show(
              keyName: 'bluetooth-details',
              debugLabel: 'Bluetooth pairing',
              builder: (_, handle) =>
                  BluetoothDetailSurface(onClose: handle.close),
            );
      },
    );
    final profile = ref.watch(shellProfileProvider);
    final displayLayout = ref.watch(displayLayoutProvider);
    final effectiveProfile = (displayLayout?.outputs.length ?? 0) > 1
        ? ShellProfile.desktop
        : profile;
    final cursorTheme = ref.watch(shellCursorThemeProvider);
    final settings = ref.watch(shellSettingsProvider);
    final accent = ref.watch(shellAccentProvider);
    final bridge = ref.watch(denialBridgeProvider);
    final cursorShapes = bridge.cursorShapes;
    final cursorPositions = bridge.cursorPositions;
    final dragIcons = bridge.dragIcons;
    final hideCursor = ref.watch(
      screenshotSelectionProvider.select(
        (session) => session?.hidesCursor ?? false,
      ),
    );
    final scene = switch (effectiveProfile) {
      ShellProfile.mobile => InputLayoutPublisher(
        child: const ShellSurfaceHost(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _ShellContent(),
              SystemLevelHudLayer(),
              NotificationBannerLayer(),
            ],
          ),
        ),
      ),
      ShellProfile.desktop => DesktopInputLayoutPublisher(
        child: const _DesktopSecureStage(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShellSurfaceHost(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DesktopShell(),
                    SystemLevelHudLayer(),
                    NotificationBannerLayer(),
                  ],
                ),
              ),
              ScreenshotSelectionLayer(),
            ],
          ),
        ),
      ),
    };
    final content = ShellCursorHost(
      theme: effectiveProfile == ShellProfile.desktop
          ? cursorTheme
          : ShellCursorThemes.standard,
      platformCursorShapes: effectiveProfile == ShellProfile.desktop
          ? cursorShapes
          : null,
      platformCursorPositions: cursorPositions,
      platformDragIcons: dragIcons,
      hideCursor: hideCursor,
      displayLayout: displayLayout,
      cursorSize: settings.appearance.cursorSize,
      child: _ShellOverlayHost(child: scene),
    );

    return ShellTheme(
      data: ShellThemeData(
        accent: accent.color,
        windowRadius: settings.appearance.windowRadius,
        panelRadius: settings.appearance.panelRadius,
        panelOpacity: settings.appearance.panelOpacity,
        backdropBlurEnabled: settings.appearance.backdropBlurEnabled,
        backdropBlurSigma: settings.appearance.backdropBlurSigma,
        backdropBlurOpacityThreshold:
            settings.appearance.backdropBlurOpacityThreshold,
        focusedWindowOpacity: settings.appearance.focusedWindowOpacity,
        unfocusedWindowOpacity: settings.appearance.unfocusedWindowOpacity,
      ),
      child: DenialLocalizationScope(
        locale: settings.localization.localeOverride,
        child: MediaQuery.fromView(
          view: View.of(context),
          child: ScrollConfiguration(
            behavior: const _ShellScrollBehavior(),
            child: DefaultTextStyle(style: ShellText.base, child: content),
          ),
        ),
      ),
    );
  }
}

/// Denial intentionally does not use WidgetsApp or Navigator, but Material
/// affordances such as tooltips still require an overlay. Keep one stable root
/// entry so provider rebuilds update the scene without reconstructing it.
class _ShellOverlayHost extends StatefulWidget {
  const _ShellOverlayHost({required this.child});

  final Widget child;

  @override
  State<_ShellOverlayHost> createState() => _ShellOverlayHostState();
}

class _ShellOverlayHostState extends State<_ShellOverlayHost> {
  late final OverlayEntry _sceneEntry;

  @override
  void initState() {
    super.initState();
    _sceneEntry = OverlayEntry(builder: (_) => widget.child);
  }

  @override
  void didUpdateWidget(covariant _ShellOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sceneEntry.markNeedsBuild();
  }

  @override
  void dispose() {
    if (_sceneEntry.mounted) {
      _sceneEntry.remove();
    }
    _sceneEntry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: <OverlayEntry>[_sceneEntry]);
  }
}

class _ShellContent extends ConsumerWidget {
  const _ShellContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frameTiming = ref.watch(shellFrameTimingOptionsProvider);
    final visual = ref.watch(
      shellControllerProvider.select(
        (state) => (
          primaryWindow: state.primaryWindow,
          launchRequest: state.launchRequest,
          launchingWindow: state.launchingWindow,
          foregroundWindow: state.foregroundWindow,
          foregroundObjectId: state.foregroundObjectId,
          appSwitchDragX: state.gestureDrag.dx,
          appSwitchTargetWindow: state.appSwitchTargetWindow,
          overviewVisible: state.overviewVisible,
          swipeDy: state.gestureDrag.dy,
          homeTransitionActive: state.homeTransitionActive,
          edgePanelProgress: state.edgePanelDragProgress,
          edgePanelViewportScroll: state.edgePanelViewportScroll,
          locked: state.locked,
          lockLayerVisible: state.lockLayerVisible,
        ),
      ),
    );
    final controller = ref.read(shellControllerProvider.notifier);
    final userAppWindows = ref.watch(_userAppWindowsProvider);
    final primaryWindow = visual.primaryWindow;
    // Hide the fullscreen app whenever the swipe-up hero owns it: during the
    // drag, while the overview is open, and through the fly-away to home.
    final heroOwnsForeground =
        visual.foregroundWindow != null &&
        (visual.overviewVisible ||
            visual.swipeDy < 0.0 ||
            visual.homeTransitionActive);
    final primaryOpacity = heroOwnsForeground ? 0.0 : 1.0;

    return DefaultTextStyle(
      style: ShellText.base,
      child: ColoredBox(
        color: ShellColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewSize = constraints.biggest;
            final edgePanelOffset =
                ShellMetrics.edgePanelHeight(viewSize) *
                visual.edgePanelProgress;
            final viewportScroll = visual.edgePanelViewportScroll
                .clamp(0.0, edgePanelOffset)
                .toDouble();
            final contentOffset = edgePanelOffset - viewportScroll;
            final applicationScene = Transform.translate(
              offset: Offset(0.0, -contentOffset),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ShellWallpaper(),
                  const RepaintBoundary(child: _LauncherLayer()),
                  if (primaryWindow != null)
                    Positioned.fill(
                      child: _PrimaryWindowStage(
                        currentWindow: primaryWindow,
                        switchTargetWindow: visual.appSwitchTargetWindow,
                        switchDragX: visual.appSwitchDragX,
                        opacity: primaryOpacity,
                      ),
                    ),
                  LaunchTransitionLayer(
                    request: visual.launchRequest,
                    window: visual.launchingWindow,
                    onCompleted: controller.completeLaunchTransition,
                  ),
                  OverviewLayer(
                    windows: userAppWindows,
                    foregroundWindow: visual.foregroundWindow,
                    foregroundObjectId: visual.foregroundObjectId,
                    visible: visual.overviewVisible,
                    swipeDy: visual.swipeDy,
                    homeTransitionActive: visual.homeTransitionActive,
                    onDismissOverview: controller.closeOverview,
                    onDismissWindow: controller.closeWindow,
                    onFocusWindow: controller.focusWindow,
                    onHomeSettled: controller.completeHomeTransition,
                  ),
                ],
              ),
            );
            const shellChromeLayer = Stack(
              fit: StackFit.expand,
              children: [
                BottomGestureHandle(),
                SystemShadeLayer(),
                EdgePanelLayer(),
              ],
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                UnlockTransitionHost(
                  locked: visual.locked,
                  lockLayerVisible: visual.lockLayerVisible,
                  onUnlockComplete: controller.completeUnlockTransition,
                  scene: applicationScene,
                  chrome: IgnorePointer(
                    ignoring: visual.launchRequest != null,
                    child: shellChromeLayer,
                  ),
                ),
                if (frameTiming.showOverlay)
                  const Positioned(
                    top: 12,
                    left: 12,
                    child: _FrameTimingOverlayHost(),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DesktopSecureStage extends ConsumerWidget {
  const _DesktopSecureStage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(
      shellControllerProvider.select(
        (state) => (locked: state.locked, visible: state.lockLayerVisible),
      ),
    );
    final animateLock = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.animations.animateLockScreen,
      ),
    );
    return UnlockTransitionHost(
      locked: lock.locked,
      lockLayerVisible: lock.visible,
      animateLock: animateLock,
      onUnlockComplete: ref
          .read(shellControllerProvider.notifier)
          .completeUnlockTransition,
      scene: child,
      chrome: const SizedBox.shrink(),
    );
  }
}

class _LauncherLayer extends ConsumerWidget {
  const _LauncherLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(
      shellControllerProvider.select((state) {
        final heroOwnsForeground =
            state.foregroundWindow != null &&
            (state.overviewVisible ||
                state.gestureDrag.dy < 0.0 ||
                state.homeTransitionActive);
        final active = state.primaryWindow == null || heroOwnsForeground;
        return (
          active: active,
          interactive:
              active &&
              !state.launchTransitionActive &&
              !state.overviewVisible &&
              !state.homeTransitionActive &&
              state.quickSettingsDragProgress == 0.0 &&
              !state.lockLayerVisible,
        );
      }),
    );
    return Offstage(
      offstage: !flags.active,
      child: IgnorePointer(
        ignoring: !flags.interactive,
        child: const HomeSurface(useShellLaunchTransition: true),
      ),
    );
  }
}

class _FrameTimingOverlayHost extends ConsumerWidget {
  const _FrameTimingOverlayHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.watch(
      shellControllerProvider.select((state) => state.windows),
    );
    final options = ref.watch(shellFrameTimingOptionsProvider);
    return ShellFrameTimingOverlayStack(
      windows: windows,
      showImportedTextureCharts: options.showImportedTextureCharts,
    );
  }
}

/// Owns the secure-lock transition without ever reparenting [scene].
///
/// Existing desktop window surfaces carry one-shot entrance state, so keeping
/// this topology stable is a correctness requirement rather than merely an
/// animation detail.
class UnlockTransitionHost extends StatefulWidget {
  const UnlockTransitionHost({
    super.key,
    required this.locked,
    required this.lockLayerVisible,
    required this.onUnlockComplete,
    required this.scene,
    required this.chrome,
    this.backdrop = const ShellWallpaper(),
    this.lockLayerBuilder,
    this.animateLock = false,
  });

  final bool locked;
  final bool lockLayerVisible;
  final VoidCallback onUnlockComplete;
  final Widget scene;
  final Widget chrome;
  final Widget backdrop;
  final Widget Function(double progress)? lockLayerBuilder;
  final bool animateLock;

  @override
  State<UnlockTransitionHost> createState() => _UnlockTransitionHostState();
}

class _UnlockTransitionHostState extends State<UnlockTransitionHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Motion.unlock,
      value: widget.lockLayerVisible ? 0.0 : 1.0,
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_handleStatus);
  }

  @override
  void didUpdateWidget(covariant UnlockTransitionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.locked && widget.locked) {
      _startLock();
      return;
    }

    if (oldWidget.locked && !widget.locked && widget.lockLayerVisible) {
      _startUnlock();
    }

    if (oldWidget.lockLayerVisible && !widget.lockLayerVisible) {
      _controller
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_handleStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final rawProgress = _controller.value;
        final progress = widget.lockLayerVisible ? rawProgress : 1.0;
        return _UnlockVerticalStack(
          progress: progress,
          backdrop: widget.backdrop,
          scene: widget.scene,
          chrome: widget.chrome,
          lockLayer: widget.lockLayerVisible
              ? widget.lockLayerBuilder?.call(rawProgress) ??
                    LockScreenLayer(
                      unlockProgress: rawProgress,
                      animateDesktopEntrance: !widget.animateLock,
                    )
              : null,
        );
      },
    );
  }

  void _startLock() {
    if (!widget.animateLock || MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0.0;
      return;
    }
    if (_controller.value <= 0.0) {
      return;
    }
    _controller.reverse();
  }

  void _startUnlock() {
    if (_controller.value >= 1.0) {
      widget.onUnlockComplete();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1.0;
      return;
    }
    _controller.forward();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onUnlockComplete();
    }
  }
}

class _UnlockVerticalStack extends StatelessWidget {
  const _UnlockVerticalStack({
    required this.progress,
    required this.backdrop,
    required this.scene,
    required this.chrome,
    required this.lockLayer,
  });

  final double progress;
  final Widget backdrop;
  final Widget scene;
  final Widget chrome;
  final Widget? lockLayer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final slide = Curves.easeInOutCubic.transform(unit(progress));
        final height = constraints.maxHeight;
        final currentLockLayer = lockLayer;
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Transform.translate(
                key: const ValueKey<String>('unlock-desktop-stage'),
                offset: Offset(0, height * (1 - slide)),
                child: IgnorePointer(
                  ignoring: currentLockLayer != null,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (currentLockLayer != null) backdrop,
                      scene,
                      chrome,
                    ],
                  ),
                ),
              ),
              if (currentLockLayer != null)
                Transform.translate(
                  key: const ValueKey<String>('unlock-lock-stage'),
                  offset: Offset(0, -height * slide),
                  child: currentLockLayer,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PrimaryWindowStage extends StatelessWidget {
  const _PrimaryWindowStage({
    required this.currentWindow,
    required this.switchTargetWindow,
    required this.switchDragX,
    required this.opacity,
  });

  final DenialWindow currentWindow;
  final DenialWindow? switchTargetWindow;
  final double switchDragX;
  final double opacity;
  static const double _switchGap = ShellMetrics.appSwitchGap;
  static const BorderRadius _switchRadius = BorderRadius.all(
    Radius.circular(18),
  );

  @override
  Widget build(BuildContext context) {
    final target = switchTargetWindow;
    if (target == null || switchDragX.abs() < 0.5) {
      final texture = WindowTextureRect(
        key: ValueKey<int>(currentWindow.objectId),
        window: currentWindow,
      );
      return opacity >= 1.0
          ? texture
          : Opacity(opacity: opacity, child: texture);
    }

    final switchStage = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final travel = width + _switchGap;
        final dx = switchDragX.clamp(-travel, travel).toDouble();
        final targetDx = dx > 0.0
            ? dx - width - _switchGap
            : dx + width + _switchGap;

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(dx, 0.0),
                child: WindowTextureRect(
                  key: ValueKey<int>(currentWindow.objectId),
                  window: currentWindow,
                  borderRadius: _switchRadius,
                ),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(targetDx, 0.0),
                child: WindowTextureRect(
                  key: ValueKey<int>(target.objectId),
                  window: target,
                  borderRadius: _switchRadius,
                ),
              ),
            ),
          ],
        );
      },
    );
    return opacity >= 1.0
        ? switchStage
        : Opacity(opacity: opacity, child: switchStage);
  }
}
