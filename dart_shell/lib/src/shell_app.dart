import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop/desktop_input_layout_publisher.dart';
import 'desktop/desktop_shell.dart';
import 'input/input_layout.dart';
import 'launcher/home_surface.dart';
import 'localization/denial_localizations.dart';
import 'models/denial_window.dart';
import 'state/cursor_theme.dart';
import 'state/bluetooth.dart';
import 'state/desktop_notifications.dart';
import 'state/display_layout.dart';
import 'state/shell_controller.dart';
import 'state/shell_profile.dart';
import 'theme/cursor_themes.dart';
import 'theme/motion.dart';
import 'theme/tokens.dart';
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

class DenialShellApp extends ConsumerWidget {
  const DenialShellApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final bridge = ref.watch(denialBridgeProvider);
    final cursorShapes = bridge.cursorShapes;
    final cursorPositions = bridge.cursorPositions;
    final dragIcons = bridge.dragIcons;
    final content = switch (effectiveProfile) {
      ShellProfile.mobile => InputLayoutPublisher(
        child: ShellCursorHost(
          theme: ShellCursorThemes.standard,
          platformCursorPositions: cursorPositions,
          platformDragIcons: dragIcons,
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
      ),
      ShellProfile.desktop => DesktopInputLayoutPublisher(
        child: ShellCursorHost(
          theme: cursorTheme,
          platformCursorShapes: cursorShapes,
          platformCursorPositions: cursorPositions,
          platformDragIcons: dragIcons,
          child: const _DesktopSecureStage(
            child: ShellSurfaceHost(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DesktopShell(),
                  SystemLevelHudLayer(),
                  NotificationBannerLayer(),
                ],
              ),
            ),
          ),
        ),
      ),
    };

    return DenialLocalizationScope(
      child: MediaQuery.fromView(
        view: View.of(context),
        child: ScrollConfiguration(
          behavior: const _ShellScrollBehavior(),
          child: _ShellOverlayHost(child: content),
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
    return UnlockTransitionHost(
      locked: lock.locked,
      lockLayerVisible: lock.visible,
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
    required this.locked,
    required this.lockLayerVisible,
    required this.onUnlockComplete,
    required this.scene,
    required this.chrome,
    this.backdrop = const ShellWallpaper(),
    this.lockLayerBuilder,
  });

  final bool locked;
  final bool lockLayerVisible;
  final VoidCallback onUnlockComplete;
  final Widget scene;
  final Widget chrome;
  final Widget backdrop;
  final Widget Function(double progress)? lockLayerBuilder;

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
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_handleStatus);
  }

  @override
  void didUpdateWidget(covariant UnlockTransitionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.locked && widget.locked) {
      _controller.stop();
      _controller.value = 0.0;
      return;
    }

    if (oldWidget.locked && !widget.locked && widget.lockLayerVisible) {
      _startUnlock();
    }

    if (oldWidget.lockLayerVisible && !widget.lockLayerVisible) {
      _controller
        ..stop()
        ..value = 0.0;
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
        return Stack(
          fit: StackFit.expand,
          children: [
            _UnlockApplicationStage(
              progress: progress,
              backdrop: widget.backdrop,
              child: widget.scene,
            ),
            _UnlockChromeStage(progress: progress, child: widget.chrome),
            if (widget.lockLayerVisible)
              _UnlockLockStage(
                progress: rawProgress,
                child:
                    widget.lockLayerBuilder?.call(rawProgress) ??
                    LockScreenLayer(unlockProgress: rawProgress),
              ),
          ],
        );
      },
    );
  }

  void _startUnlock() {
    if (_controller.isAnimating || _controller.value >= 1.0) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1.0;
      return;
    }
    _controller.forward(from: 0.0);
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onUnlockComplete();
    }
  }
}

class _UnlockApplicationStage extends StatelessWidget {
  const _UnlockApplicationStage({
    required this.progress,
    required this.backdrop,
    required this.child,
  });

  final double progress;
  final Widget backdrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final approach = Motion.md3EmphasizedDecelerate.transform(
      interval(progress, 0.04, 0.86),
    );
    final opacity =
        0.90 +
        0.10 *
            Motion.md3EmphasizedDecelerate.transform(
              interval(progress, 0.02, 0.36),
            );
    final scale = 0.972 + 0.028 * approach;

    return Stack(
      fit: StackFit.expand,
      children: [
        Visibility(visible: progress < 1.0, child: backdrop),
        ClipRect(
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(scale: scale, child: child),
          ),
        ),
        if (progress > 0.0 && progress < 1.0)
          IgnorePointer(
            child: CustomPaint(
              painter: _UnlockAppRevealPainter(progress: progress),
            ),
          ),
      ],
    );
  }
}

class _UnlockChromeStage extends StatelessWidget {
  const _UnlockChromeStage({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final opacity = Motion.md3EmphasizedDecelerate.transform(
      interval(progress, 0.42, 0.78),
    );
    return Opacity(opacity: opacity, child: child);
  }
}

class _UnlockLockStage extends StatelessWidget {
  const _UnlockLockStage({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final exit = Curves.easeInOutCubic.transform(progress);
    final opacity = 1.0 - interval(progress, 0.18, 0.95);
    return Transform.translate(
      offset: Offset(0.0, -214.0 * exit),
      child: Transform.scale(
        scale: 1.0 - 0.046 * exit,
        alignment: Alignment.topCenter,
        child: Opacity(opacity: opacity, child: child),
      ),
    );
  }
}

class _UnlockAppRevealPainter extends CustomPainter {
  const _UnlockAppRevealPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    final glowPhase = interval(p, 0.0, 0.84);
    final pulse = math.sin(math.pi * glowPhase).clamp(0.0, 1.0).toDouble();
    final sweep = Curves.easeOutCubic.transform(interval(p, 0.0, 0.88));
    final rect = Offset.zero & size;

    final dimPaint = Paint()
      ..color = const Color(
        0xff050608,
      ).withValues(alpha: 0.22 * (1.0 - interval(p, 0.10, 0.70)));
    canvas.drawRect(rect, dimPaint);

    final vignettePaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.92,
        colors: [
          ShellColors.textPrimary.withValues(alpha: 0.08 * pulse),
          ShellColors.lockAccent.withValues(alpha: 0.05 * pulse),
          const Color(0x00000000),
        ],
        stops: const [0.0, 0.42, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, vignettePaint);

    final bandCenter = size.height * (0.96 - 0.88 * sweep);
    final bandHeight = size.height * (0.20 + 0.18 * pulse);
    final bandRect = Rect.fromLTWH(
      0.0,
      bandCenter - bandHeight * 0.5,
      size.width,
      bandHeight,
    );
    final bandPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0x00000000),
          ShellColors.lockAccent.withValues(alpha: 0.32 * pulse),
          ShellColors.textPrimary.withValues(alpha: 0.20 * pulse),
          ShellColors.accent.withValues(alpha: 0.16 * pulse),
          const Color(0x00000000),
        ],
        stops: const [0.0, 0.40, 0.50, 0.58, 1.0],
      ).createShader(bandRect);
    canvas.drawRect(bandRect, bandPaint);

    final edgePaint = Paint()
      ..color = ShellColors.textPrimary.withValues(alpha: 0.42 * pulse)
      ..strokeWidth = 1.6;
    canvas.drawLine(
      Offset(0.0, bandCenter),
      Offset(size.width, bandCenter),
      edgePaint,
    );

    final shardPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = ShellColors.lockAccent.withValues(alpha: 0.24 * pulse);
    for (var i = 0; i < 11; i++) {
      final startX = size.width * (-0.24 + i * 0.14) + 88.0 * sweep;
      final startY = bandCenter - bandHeight * (0.42 - i * 0.035);
      canvas.drawLine(
        Offset(startX, startY),
        Offset(startX + size.width * 0.24, startY + bandHeight * 0.84),
        shardPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UnlockAppRevealPainter oldDelegate) {
    return oldDelegate.progress != progress;
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
