import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/bottom_gesture_handle.dart';
import '../../widgets/edge_panel_layer.dart';
import '../../widgets/shade/system_shade_layer.dart';
import 'mobile_launcher_layer.dart';
import 'mobile_window_layers.dart';

/// Denial's built-in phone/tablet application scene.
///
/// All compositor lifecycle behavior is supplied by [DenialShell]; this class
/// contains only the visual feature policy of the stock mobile experience.
class MobileApplicationScene extends StatefulWidget {
  const MobileApplicationScene({super.key});

  @override
  State<MobileApplicationScene> createState() => _MobileApplicationSceneState();
}

class _MobileApplicationSceneState extends State<MobileApplicationScene> {
  final _overviewPresentationActive = ValueNotifier(false);

  @override
  void dispose() {
    _overviewPresentationActive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.shellColors.background,
      child: MobileKeyboardViewport(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ShellWallpaper(),
            const RepaintBoundary(child: MobileLauncherLayer()),
            MobilePrimaryWindowLayer(
              overviewPresentationActive: _overviewPresentationActive,
            ),
            const MobileLaunchLayer(),
            MobileOverviewLayer(
              onPresentationChanged: (active) =>
                  _overviewPresentationActive.value = active,
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
