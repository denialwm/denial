import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launcher/home_surface.dart';
import '../../widgets/shade/shade_progress.dart';

/// Visibility and interaction policy for the stock launcher feature.
class MobileLauncherLayer extends ConsumerWidget {
  const MobileLauncherLayer({
    super.key,
    required this.contentOpacity,
    required this.overviewPresentationActive,
  });

  final Animation<double> contentOpacity;
  final ValueListenable<bool> overviewPresentationActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(
      shellControllerProvider.select((state) {
        final active =
            state.primaryWindow == null || state.homeTransitionActive;
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
    final opacity = _HomeContentOpacity(
      first: contentOpacity,
      next: ReverseAnimation(ref.watch(shadeProgressProvider)),
    );
    // Keep the grid mounted while recents and the shade fade its content.
    // Phase changes alone update interaction/tickers; animation ticks stay
    // at the renderer and share the existing composited opacity layer.
    return ValueListenableBuilder<bool>(
      valueListenable: overviewPresentationActive,
      builder: (context, overviewActive, _) => TickerMode(
        enabled: !overviewActive,
        child: HomeSurface(
          active: flags.active,
          interactive: flags.interactive && !overviewActive,
          contentOpacity: opacity,
          useShellLaunchTransition: true,
        ),
      ),
    );
  }
}

class _HomeContentOpacity extends CompoundAnimation<double> {
  _HomeContentOpacity({required super.first, required super.next});

  @override
  double get value => first.value * next.value;
}
