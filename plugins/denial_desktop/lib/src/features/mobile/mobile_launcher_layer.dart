import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launcher/home_surface.dart';
import '../../widgets/shade/shade_expansion_motion.dart';
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
      referenceShellProvider.select((state) {
        final active =
            state.primaryWindow == null || state.homeTransitionActive;
        return (
          active: active,
          interactive:
              active &&
              !state.launchTransitionActive &&
              !state.overviewVisible &&
              state.gesture == GestureDragPhase.idle &&
              !state.quickSettingsEngaged &&
              !state.lockLayerVisible,
        );
      }),
    );
    final shade = ref.watch(shadeProgressProvider);
    final showsHome = ref.read(referenceShellProvider.notifier).deck.showsHome;
    final opacity = _HomeContentOpacity(
      first: contentOpacity,
      // The frost fades the home content itself and then hides it; fading
      // the content too would composite it through a layer on every frame.
      next: shadeFrostOccludes(context)
          ? shade.drive(_hiddenOnceCovered)
          : ReverseAnimation(shade),
    );
    // Keep the grid mounted while recents and the shade fade its content.
    // Phase changes alone update interaction/tickers; animation ticks stay
    // at the renderer and share the existing composited opacity layer.
    return ValueListenableBuilder<bool>(
      valueListenable: overviewPresentationActive,
      // Home takes touches as soon as nothing above it holds them: while an
      // app flies back into its icon or recents slides away, so a quick
      // close and reopen never waits for an animation to end.
      builder: (context, overviewActive, _) => ValueListenableBuilder<bool>(
        // An app sliding in over home is in front already; home stays
        // until it is covered.
        valueListenable: showsHome,
        builder: (context, showsHome, _) => TickerMode(
          enabled: !overviewActive || flags.interactive,
          child: HomeSurface(
            active: flags.active || showsHome,
            interactive: flags.interactive,
            contentOpacity: opacity,
          ),
        ),
      ),
    );
  }
}

final _hiddenOnceCovered = Animatable<double>.fromCallback(
  (progress) => ColorOsShadeMotion.blurFraction(progress) >= 1 ? 0.0 : 1.0,
);

class _HomeContentOpacity extends CompoundAnimation<double> {
  _HomeContentOpacity({required super.first, required super.next});

  @override
  double get value => first.value * next.value;
}
