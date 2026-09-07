import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mobile_primary_window_stage.dart';

/// Each animated layer observes only the state it presents.
class MobilePrimaryWindowLayer extends ConsumerStatefulWidget {
  const MobilePrimaryWindowLayer({
    super.key,
    required this.overviewPresentationActive,
  });

  final ValueListenable<bool> overviewPresentationActive;

  @override
  ConsumerState<MobilePrimaryWindowLayer> createState() =>
      _MobilePrimaryWindowLayerState();
}

class _MobilePrimaryWindowLayerState
    extends ConsumerState<MobilePrimaryWindowLayer> {
  final _dragX = ValueNotifier(0.0);

  @override
  void dispose() {
    _dragX.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      shellControllerProvider.select((state) => state.gestureDrag.dx),
      (_, next) => _dragX.value = next,
    );
    _dragX.value = ref.read(shellControllerProvider).gestureDrag.dx;
    final visual = ref.watch(
      shellControllerProvider.select(
        (state) => (
          window: state.primaryWindow,
          target: state.appSwitchTargetWindow,
          switching: state.gestureDrag.dx.abs() >= 0.5,
          heroOwnsForeground:
              state.foregroundWindow != null &&
              (state.overviewVisible ||
                  state.gestureDrag.dy < 0.0 ||
                  state.homeTransitionActive),
        ),
      ),
    );
    final window = visual.window;
    if (window == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<bool>(
      valueListenable: widget.overviewPresentationActive,
      builder: (context, overviewActive, _) {
        // Gesture state resets on release; the hero still owns presentation
        // until its return animation has reached the normal app bounds.
        final heroOwnsForeground = visual.heroOwnsForeground || overviewActive;
        if (window.isLocalFlutter && heroOwnsForeground) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: MobilePrimaryWindowStage(
            currentWindow: window,
            switchTargetWindow: visual.switching ? visual.target : null,
            switchDragX: _dragX,
            opacity: heroOwnsForeground ? 0.0 : 1.0,
          ),
        );
      },
    );
  }
}

class MobileLaunchLayer extends ConsumerWidget {
  const MobileLaunchLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launch = ref.watch(
      shellControllerProvider.select(
        (state) =>
            (request: state.launchRequest, window: state.launchingWindow),
      ),
    );
    return LaunchTransitionLayer(
      request: launch.request,
      window: launch.window,
      onCompleted: ref
          .read(shellControllerProvider.notifier)
          .completeLaunchTransition,
    );
  }
}

class MobileOverviewLayer extends ConsumerStatefulWidget {
  const MobileOverviewLayer({super.key, required this.onPresentationChanged});

  final ValueChanged<bool> onPresentationChanged;

  @override
  ConsumerState<MobileOverviewLayer> createState() =>
      _MobileOverviewLayerState();
}

class _MobileOverviewLayerState extends ConsumerState<MobileOverviewLayer> {
  final _dragY = ValueNotifier(0.0);

  @override
  void dispose() {
    _dragY.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      shellControllerProvider.select((state) => state.gestureDrag.dy),
      (_, next) => _dragY.value = next,
    );

    final overview = ref.watch(
      shellControllerProvider.select(
        (state) => (
          window: state.foregroundWindow,
          objectId: state.foregroundObjectId,
          visible: state.overviewVisible,
          homeActive: state.homeTransitionActive,
        ),
      ),
    );
    final controller = ref.read(shellControllerProvider.notifier);
    return OverviewLayer(
      windows: ref.watch(userAppWindowsProvider),
      foregroundWindow: overview.window,
      foregroundObjectId: overview.objectId,
      visible: overview.visible,
      swipeDy: _dragY,
      homeTransitionActive: overview.homeActive,
      onPresentationChanged: widget.onPresentationChanged,
      onDismissOverview: controller.closeOverview,
      onDismissWindow: controller.closeWindow,
      onFocusWindow: controller.focusWindow,
      onHomeSettled: controller.completeHomeTransition,
    );
  }
}
