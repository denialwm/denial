import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launcher/home_surface.dart';

/// Visibility and interaction policy for the stock launcher feature.
class MobileLauncherLayer extends ConsumerWidget {
  const MobileLauncherLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(
      shellControllerProvider.select((state) {
        final active =
            !state.overviewVisible &&
            state.gestureDrag.dy >= 0 &&
            (state.primaryWindow == null || state.homeTransitionActive);
        return (
          active: active,
          interactive:
              active &&
              !state.launchTransitionActive &&
              !state.overviewVisible &&
              state.gestureDrag == Offset.zero &&
              !state.homeTransitionActive &&
              state.quickSettingsDragProgress == 0.0 &&
              !state.lockLayerVisible,
        );
      }),
    );
    return HomeSurface(
      active: flags.active,
      interactive: flags.interactive,
      useShellLaunchTransition: true,
    );
  }
}
