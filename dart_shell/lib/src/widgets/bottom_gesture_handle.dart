import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/input_layout.dart';
import '../state/shell_controller.dart';
import '../state/shell_state.dart';
import '../theme/motion.dart';
import 'gesture_pill.dart';

/// The home pill at the bottom of the screen. Swiping up opens the overview (or
/// closes it when already open); swiping horizontally switches between adjacent
/// apps with a spring-settled slide.
class BottomGestureHandle extends ConsumerStatefulWidget {
  const BottomGestureHandle({super.key});

  @override
  ConsumerState<BottomGestureHandle> createState() =>
      _BottomGestureHandleState();
}

class _BottomGestureHandleState extends ConsumerState<BottomGestureHandle>
    with SingleTickerProviderStateMixin {
  static const double _closeDistance = 72.0;
  static const double _switchDistance = 82.0;
  static const double _flickVelocity = 650.0;
  static const double _switchFlickVelocity = 720.0;
  static const double _axisLockRatio = 1.18;

  /// Upward fling faster than this goes straight to home; a slower-but-longer
  /// pull opens recents once it passes [_recentsTravelFraction] of the screen.
  static const double _homeFlickVelocity = 1100.0;
  static const double _recentsTravelFraction = 0.16;

  late final AnimationController _switchController;
  Animation<double>? _switchAnimation;
  int _switchDirection = 0;

  // Keep an independent velocity estimate for compositor-generated pointer
  // streams, where event coalescing can otherwise under-report a short flick.
  final Stopwatch _panClock = Stopwatch();
  VelocityTracker _panVelocity = VelocityTracker.withKind(
    PointerDeviceKind.touch,
  );
  Offset _panTravel = Offset.zero;

  @override
  void initState() {
    super.initState();
    _switchController = AnimationController(vsync: this)
      ..addListener(_syncSwitchAnimation)
      ..addStatusListener(_handleSwitchStatus);
  }

  @override
  void dispose() {
    _switchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = ref.watch(
      shellControllerProvider.select(
        (state) => (
          gestureDrag: state.gestureDrag,
          overviewVisible: state.overviewVisible,
          appSwitchTargetWindow: state.appSwitchTargetWindow,
        ),
      ),
    );
    final controller = ref.read(shellControllerProvider.notifier);
    final lift = (-visual.gestureDrag.dy / 280.0).clamp(0.0, 1.0);
    final recentsTravel =
        MediaQuery.sizeOf(context).height * _recentsTravelFraction;
    final armed = visual.overviewVisible
        ? visual.gestureDrag.dy > _closeDistance
        : -visual.gestureDrag.dy > recentsTravel ||
              _horizontalSwitchArmed(
                visual.gestureDrag,
                hasTarget: visual.appSwitchTargetWindow != null,
              );

    return Positioned(
      left: 0,
      right: 0,
      bottom: ShellMetrics.gestureBottomInset,
      child: Center(
        child: Transform.translate(
          offset: Offset(0, -lift * 8.0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              _switchController.stop();
              _switchAnimation = null;
              _switchDirection = 0;
              controller.resetGestureDrag();
              _beginPanTracking();
            },
            onPanUpdate: (details) {
              controller.updateGestureDrag(details.delta);
              _trackPan(details.delta);
            },
            onPanCancel: controller.resetGestureDrag,
            onPanEnd: (details) => _handlePanEnd(controller, details),
            child: SizedBox(
              width: ShellMetrics.gestureHitWidth,
              height: ShellMetrics.gestureHitHeight,
              child: Center(child: GesturePill(armed: armed)),
            ),
          ),
        ),
      ),
    );
  }

  void _handlePanEnd(ShellController controller, DragEndDetails details) {
    _panClock.stop();
    final currentState = ref.read(shellControllerProvider);
    // Raw travel (not the axis-locked visual drag, which is zeroed for short
    // gestures) and the stronger of our / Flutter's velocity estimate.
    final drag = _panTravel;
    final velocity = _strongerVelocity(
      _panVelocity.getVelocity().pixelsPerSecond,
      details.velocity.pixelsPerSecond,
    );

    if (currentState.overviewVisible) {
      if (drag.dy > _closeDistance || velocity.dy > _flickVelocity) {
        controller.closeOverview();
      } else {
        controller.resetGestureDrag();
      }
      return;
    }

    final switchDirection = _horizontalSwitchDirection(
      currentState,
      drag,
      velocity,
    );
    if (switchDirection != 0) {
      _animateSwitch(
        controller: controller,
        state: currentState,
        direction: switchDirection,
        velocityX: velocity.dx,
      );
      return;
    }

    // Vertical outcome: a fast up-flick flies home, a longer pull opens
    // recents, anything smaller snaps the app back.
    final hasForeground = currentState.foregroundWindow != null;
    final upTravel = -drag.dy;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (currentState.launchTransitionActive) {
      if (velocity.dy < -_homeFlickVelocity ||
          upTravel > screenHeight * _recentsTravelFraction) {
        controller.goHome();
      } else {
        controller.resetGestureDrag();
      }
      return;
    }
    if (hasForeground && velocity.dy < -_homeFlickVelocity) {
      controller.goHome();
    } else if (upTravel > screenHeight * _recentsTravelFraction) {
      controller.openOverview();
    } else {
      controller.resetGestureDrag();
    }
  }

  void _beginPanTracking() {
    _panTravel = Offset.zero;
    _panVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
    _panClock
      ..reset()
      ..start();
    _panVelocity.addPosition(Duration.zero, _panTravel);
  }

  void _trackPan(Offset delta) {
    _panTravel += delta;
    _panVelocity.addPosition(_panClock.elapsed, _panTravel);
  }

  /// Per-axis, keeps whichever source reports the larger magnitude, so a usable
  /// fling survives even if one estimator under-reports.
  Offset _strongerVelocity(Offset a, Offset b) {
    return Offset(
      a.dx.abs() >= b.dx.abs() ? a.dx : b.dx,
      a.dy.abs() >= b.dy.abs() ? a.dy : b.dy,
    );
  }

  bool _horizontalSwitchArmed(Offset drag, {required bool hasTarget}) {
    if (!hasTarget) {
      return false;
    }
    return drag.dx.abs() > _switchDistance &&
        drag.dx.abs() > drag.dy.abs() * _axisLockRatio;
  }

  int _horizontalSwitchDirection(
    ShellState state,
    Offset drag,
    Offset velocity,
  ) {
    if (state.openAppWindowCount < 2 || state.overviewVisible) {
      return 0;
    }

    final horizontalIntent =
        drag.dx.abs() > drag.dy.abs() * _axisLockRatio ||
        velocity.dx.abs() > velocity.dy.abs() * _axisLockRatio;
    if (!horizontalIntent) {
      return 0;
    }

    var direction = 0;
    if (velocity.dx.abs() > _switchFlickVelocity) {
      direction = velocity.dx > 0.0 ? -1 : 1;
    } else if (drag.dx.abs() > _switchDistance) {
      direction = drag.dx > 0.0 ? -1 : 1;
    }

    if (direction == 0 || state.adjacentOpenAppWindow(direction) == null) {
      return 0;
    }
    return direction;
  }

  /// Slides the current app off-screen toward [direction] until the incoming
  /// app lands centred. The switch is a directed commit, so it rides a curve
  /// whose duration is derived from the fling velocity (a faster flick lands
  /// sooner) rather than a spring, which would creep at the tail.
  void _animateSwitch({
    required ShellController controller,
    required ShellState state,
    required int direction,
    required double velocityX,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0.0) {
      controller.completeAdjacentWindowSwitch(direction);
      return;
    }

    final startX = state.gestureDrag.dx;
    final travel = width + ShellMetrics.appSwitchGap;
    final endX = direction < 0 ? travel : -travel;
    final distance = (endX - startX).abs();
    final speed = math.max(velocityX.abs(), 1450.0);
    final durationMs = ((distance / speed) * 1000.0).clamp(170.0, 340.0);

    _switchDirection = direction;
    _switchAnimation = Tween<double>(begin: startX, end: endX).animate(
      CurvedAnimation(parent: _switchController, curve: Motion.emphasized),
    );
    _switchController.duration = Duration(milliseconds: durationMs.round());
    _switchController.forward(from: 0.0);
  }

  void _syncSwitchAnimation() {
    final value = _switchAnimation?.value;
    if (value == null) {
      return;
    }
    ref
        .read(shellControllerProvider.notifier)
        .setGestureDragForAnimation(Offset(value, 0.0));
  }

  void _handleSwitchStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _switchDirection == 0) {
      return;
    }
    final direction = _switchDirection;
    _switchAnimation = null;
    _switchDirection = 0;
    ref
        .read(shellControllerProvider.notifier)
        .completeAdjacentWindowSwitch(direction);
  }
}
