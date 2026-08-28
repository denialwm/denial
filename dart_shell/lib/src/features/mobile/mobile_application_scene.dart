import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/bottom_gesture_handle.dart';
import '../../widgets/edge_panel_layer.dart';
import '../../widgets/shade/system_shade_layer.dart';
import 'mobile_launcher_layer.dart';
import 'mobile_primary_window_stage.dart';

/// Denial's built-in phone/tablet application scene.
///
/// All compositor lifecycle behavior is supplied by [DenialShell]; this class
/// contains only the visual feature policy of the stock mobile experience.
class MobileApplicationScene extends ConsumerWidget {
  const MobileApplicationScene({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        ),
      ),
    );
    final controller = ref.read(shellControllerProvider.notifier);
    final primaryWindow = visual.primaryWindow;
    final heroOwnsForeground =
        visual.foregroundWindow != null &&
        (visual.overviewVisible ||
            visual.swipeDy < 0.0 ||
            visual.homeTransitionActive);
    final primaryOpacity = heroOwnsForeground ? 0.0 : 1.0;

    return ColoredBox(
      color: context.shellColors.background,
      child: MobileKeyboardViewport(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ShellWallpaper(),
            const RepaintBoundary(child: MobileLauncherLayer()),
            if (primaryWindow != null &&
                !(primaryWindow.isLocalFlutter && heroOwnsForeground))
              Positioned.fill(
                child: MobilePrimaryWindowStage(
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
              windows: ref.watch(userAppWindowsProvider),
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
      ),
    );
  }
}

/// Gesture and shade chrome for the stock mobile shell.
class MobileShellChrome extends ConsumerWidget {
  const MobileShellChrome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launchActive = ref.watch(
      shellControllerProvider.select((state) => state.launchRequest != null),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        const BottomGestureHandle(),
        SystemShadeLayer(ignoring: launchActive),
      ],
    );
  }
}
