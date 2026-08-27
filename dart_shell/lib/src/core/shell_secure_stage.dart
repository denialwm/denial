import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../widgets/lock/lock_screen_layer.dart';
import '../widgets/output_relative_translation.dart';
import '../widgets/shell_wallpaper.dart';

/// Applies Denial's secure lock surface and transition to a feature scene.
///
/// Feature code supplies ordinary [scene] and [chrome] widgets. Lock state,
/// input isolation, and compositor acknowledgement remain core concerns.
class ShellSecureStage extends ConsumerWidget {
  const ShellSecureStage({
    super.key,
    required this.scene,
    this.chrome = const SizedBox.shrink(),
    this.useConfiguredLockAnimation = false,
  });

  final Widget scene;
  final Widget chrome;
  final bool useConfiguredLockAnimation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(
      shellControllerProvider.select(
        (state) => (locked: state.locked, visible: state.lockLayerVisible),
      ),
    );
    final animateLock = useConfiguredLockAnimation
        ? ref.watch(
            shellSettingsProvider.select(
              (settings) => settings.animations.animateLockScreen,
            ),
          )
        : false;
    return UnlockTransitionHost(
      locked: lock.locked,
      lockLayerVisible: lock.visible,
      animateLock: animateLock,
      onUnlockComplete: ref
          .read(shellControllerProvider.notifier)
          .completeUnlockTransition,
      scene: scene,
      chrome: chrome,
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
  final Widget Function(Animation<double> progress)? lockLayerBuilder;
  final bool animateLock;

  @override
  State<UnlockTransitionHost> createState() => _UnlockTransitionHostState();
}

class _UnlockTransitionHostState extends State<UnlockTransitionHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  var _unlockCompletionScheduled = false;

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
    final lockLayer = widget.lockLayerVisible
        ? widget.lockLayerBuilder?.call(_controller) ??
              LockScreenLayer(
                unlockProgress: _controller,
                animateDesktopEntrance: !widget.animateLock,
              )
        : null;
    return AnimatedBuilder(
      animation: _controller,
      child: lockLayer,
      builder: (context, child) {
        final rawProgress = _controller.value;
        final progress = widget.lockLayerVisible ? rawProgress : 1.0;
        return _UnlockVerticalStack(
          progress: progress,
          backdrop: widget.backdrop,
          scene: widget.scene,
          chrome: widget.chrome,
          lockLayer: child,
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
    MotionTelemetry.observe(
      _controller,
      _controller.reverse(),
      'session_lock',
      target: 0.0,
    );
  }

  void _startUnlock() {
    if (_controller.value >= 1.0) {
      _scheduleUnlockCompletion();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 1.0;
      _scheduleUnlockCompletion();
      return;
    }
    final transition = MotionTelemetry.observe(
      _controller,
      _controller.forward(),
      'session_unlock',
      target: 1.0,
    );
    transition.whenCompleteOrCancel(_completeUnlockIfSettled);
  }

  void _completeUnlockIfSettled() {
    if (!mounted || widget.locked || !widget.lockLayerVisible) {
      return;
    }
    if (_controller.value >= 1.0) {
      widget.onUnlockComplete();
    }
  }

  void _scheduleUnlockCompletion() {
    if (_unlockCompletionScheduled) {
      return;
    }
    _unlockCompletionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unlockCompletionScheduled = false;
      _completeUnlockIfSettled();
    });
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _scheduleUnlockCompletion();
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
        final slide = Motion.sessionTransitionCurve.transform(unit(progress));
        final currentLockLayer = lockLayer;
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              OutputRelativeTranslation(
                key: const ValueKey<String>('unlock-desktop-stage'),
                offsetFactor: Offset(0, 1 - slide),
                fallbackSize: constraints.biggest,
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
                OutputRelativeTranslation(
                  key: const ValueKey<String>('unlock-lock-stage'),
                  offsetFactor: Offset(0, -slide),
                  fallbackSize: constraints.biggest,
                  child: currentLockLayer,
                ),
            ],
          ),
        );
      },
    );
  }
}
