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
