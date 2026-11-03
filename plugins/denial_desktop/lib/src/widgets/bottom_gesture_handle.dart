import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/rendering.dart' show CompositedTranslation;
import 'package:denial_flutter_sdk/system_services.dart'
    show hapticsServiceProvider;

import 'liquid_pill.dart';

/// The home pill at the bottom of the screen. An upward pull arms recents,
/// with a tap of the haptic motor, and opens it on release; a fast flick
/// sends an app home or opens recents from home. A downward swipe
/// closes recents, and a horizontal swipe moves the row of apps, whose
/// release sends it to the adjacent app or back. A swipe that starts while
/// the apps still move takes them from where they are: sideways it holds
/// the row, upward it lifts the app in front as the row settles.
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

  /// A faster upward fling sends an app home or opens recents from home. A
  /// slower pull arms recents after [_recentsArmFraction] of the screen and
  /// stays armed until it comes back below [_recentsDisarmFraction], so a
  /// finger resting at the threshold does not flicker it.
  static const double _homeFlickVelocity = 1100.0;
  static const double _recentsArmFraction = 0.06;
  static const double _recentsDisarmFraction = 0.045;

  // The pill follows the drag without rebuilding: its lift moves a retained
  // layer, and only a change of [_armed] rebuilds it.
  late final ValueListenable<Offset> _drag;
  final _lift = ValueNotifier(Offset.zero);
  final _armed = ValueNotifier(false);

  /// How the pill looks: liquid that follows the finger. It never decides
  /// anything about the gesture.
  late final PillLiquid _liquid = PillLiquid(this);
  bool _overviewVisible = false;
  bool _hasSwitchTarget = false;
  double _recentsArmTravel = double.infinity;
  double _recentsDisarmTravel = double.infinity;
  bool _recentsArmed = false;

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
    _drag = ref.read(referenceShellProvider.notifier).gestureDrag
      ..addListener(_dragged);
    ref.read(hapticsServiceProvider).prewarm();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _liquid.reduced = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _liquid.dispose();
    _drag.removeListener(_dragged);
    _lift.dispose();
    _armed.dispose();
    super.dispose();
  }

  void _dragged() {
    final armed = _recentsArmed;
    _syncPill();
    if (_recentsArmed != armed) {
      ref.read(referenceShellProvider.notifier).armRecents(_recentsArmed);
    }
  }

  void _syncPill() {
    final drag = _drag.value;
    final lift = (-drag.dy / ReferenceShellMetrics.gesturePillLiftTravel).clamp(
      0.0,
      1.0,
    );
    _lift.value = Offset(0, -lift * 8.0);
    final up = -drag.dy;
    final recents =
        !_overviewVisible &&
        up > (_recentsArmed ? _recentsDisarmTravel : _recentsArmTravel);
    if (recents != _recentsArmed) {
      _recentsArmed = recents;
      if (recents) ref.read(hapticsServiceProvider).pulse();
    }
    _armed.value = _overviewVisible
        ? drag.dy > _closeDistance
        : recents || _horizontalSwitchArmed(drag, hasTarget: _hasSwitchTarget);
    final progress = _overviewVisible
        ? drag.dy / _closeDistance
        : [
            up / _recentsArmTravel,
            if (_hasSwitchTarget) drag.dx.abs() / _switchDistance,
          ].reduce((a, b) => a > b ? a : b);
    _liquid.arm(progress, armed: _armed.value);
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(
      referenceShellProvider.select(
        (state) => (
          overviewVisible: state.overviewVisible,
          hasSwitchTarget: state.canSwitchApps,
        ),
      ),
    );
    _overviewVisible = shell.overviewVisible;
    _hasSwitchTarget = shell.hasSwitchTarget;
    final size = MediaQuery.sizeOf(context);
    _recentsArmTravel = size.height * _recentsArmFraction;
    _recentsDisarmTravel = size.height * _recentsDisarmFraction;
    _syncPill();
    final controller = ref.read(referenceShellProvider.notifier);

    return Positioned(
      left: 0,
      right: 0,
      bottom: ReferenceShellMetrics.gestureBottomInset,
      child: Center(
        child: RepaintBoundary(
          child: Listener(
            onPointerDown: (event) => _liquid.touch(
              event.localPosition.dx -
                  ReferenceShellMetrics.gestureHitWidth / 2,
            ),
            // A tap, or a swipe the pan has not settled yet.
            onPointerUp: (_) => _liquid.release(PillRelease.settle),
            onPointerCancel: (_) => _liquid.release(PillRelease.settle),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                _beginPanTracking();
                controller.resetGestureDrag();
              },
              onPanUpdate: (details) {
                _trackPan(details.delta);
                controller.updateGestureDrag(details.delta);
                _liquid.drag(
                  _panTravel,
                  _panVelocity.getVelocity().pixelsPerSecond.dx,
                );
              },
              onPanCancel: () {
                controller.resetGestureDrag();
                _liquid.release(PillRelease.settle);
              },
              onPanEnd: (details) => _handlePanEnd(controller, details),
              child: SizedBox(
                width: ReferenceShellMetrics.gestureHitWidth,
                height: ReferenceShellMetrics.gestureHitHeight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Center(
                    child: CompositedTranslation(
                      translation: _lift,
                      child: LiquidPill(liquid: _liquid),
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

  void _handlePanEnd(
    ReferenceShellController controller,
    DragEndDetails details,
  ) {
    _panClock.stop();
    // Raw travel (not the axis-locked visual drag, which is zeroed for short
    // gestures) and the stronger of our / Flutter's velocity estimate.
    final drag = _panTravel;
    final velocity = _strongerVelocity(
      _panVelocity.getVelocity().pixelsPerSecond,
      details.velocity.pixelsPerSecond,
    );
    final acted = _resolvePan(controller, drag, velocity);
    _liquid.release(
      acted ? PillRelease.launch : PillRelease.settle,
      velocity: velocity,
    );
  }

  /// Whether the swipe did something: closed recents, moved the row, went
  /// home or opened recents.
  bool _resolvePan(
    ReferenceShellController controller,
    Offset drag,
    Offset velocity,
  ) {
    final currentState = ref.read(referenceShellProvider);

    if (currentState.overviewVisible) {
      if (drag.dy > _closeDistance || velocity.dy > _flickVelocity) {
        controller.closeOverview();
        return true;
      }
      controller.resetGestureDrag(releaseVelocity: velocity.dy);
      return false;
    }

    if (controller.holdsRow || _horizontalFlick(currentState, drag, velocity)) {
      controller.releaseRow(velocity.dx);
      return drag.dx.abs() > _switchDistance ||
          velocity.dx.abs() > _switchFlickVelocity;
    }

    // A fast up-flick sends an app home or opens recents when already home.
    // A longer pull also opens recents; smaller gestures cancel.
    final hasForeground = currentState.foregroundWindow != null;
    final armed = _recentsArmed || -drag.dy > _recentsArmTravel;
    if (currentState.launchTransitionActive) {
      if (velocity.dy < -_homeFlickVelocity || armed) {
        controller.goHome(releaseVelocity: velocity.dy);
        return true;
      }
      controller.resetGestureDrag(releaseVelocity: velocity.dy);
      return false;
    }
    if (velocity.dy < -_homeFlickVelocity) {
      if (hasForeground) {
        controller.goHome(releaseVelocity: velocity.dy);
      } else {
        controller.openOverview(releaseVelocity: velocity.dy);
      }
      return true;
    } else if (armed) {
      controller.openOverview(releaseVelocity: velocity.dy);
      return true;
    }
    controller.resetGestureDrag(releaseVelocity: velocity.dy);
    return false;
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

  /// A short sideways flick, too quick for the axis to lock, still switches.
  bool _horizontalFlick(
    ReferenceShellState state,
    Offset drag,
    Offset velocity,
  ) {
    if (state.launchTransitionActive ||
        velocity.dx.abs() <= _switchFlickVelocity) {
      return false;
    }
    return drag.dx.abs() > drag.dy.abs() * _axisLockRatio ||
        velocity.dx.abs() > velocity.dy.abs() * _axisLockRatio;
  }
}
