import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';

import 'package:denial_flutter_sdk/rendering.dart' show FrostedBackdrop;

import '../../widgets/overview/app_deck_layer.dart';
import '../../widgets/shade/shade_progress.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mobile_primary_window_stage.dart';
import '../../state/phone_desk.dart';

/// The app in front at rest. While the deck presents, it draws the apps.
class MobilePrimaryWindowLayer extends ConsumerWidget {
  const MobilePrimaryWindowLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visual = ref.watch(
      referenceShellProvider.select(
        (state) => (
          window: state.primaryWindow,
          behind: state.windowsBehindPrimary,
          homeActive: state.homeTransitionActive,
        ),
      ),
    );
    final window = visual.window;
    if (window == null) return const SizedBox.shrink();
    final deck = ref.read(referenceShellProvider.notifier).deck;
    final topInset = ref.watch(mobilePresentationTopInsetProvider);
    // The shade's frosted glass hides the app completely once established.
    // Leaving the app in the scene would composite it, and everything above
    // it, for every frame the shade moves or the app draws behind it.
    final shadeOccludes = shadeFrostOccludes(context);
    return ValueListenableBuilder<bool>(
      valueListenable: deck.presenting,
      builder: (context, presenting, _) {
        final hidden = presenting || visual.homeActive;
        // An in-bundle app's widget tree can live in one place at a time.
        if (window.isLocalFlutter && hidden) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: ref.watch(shadeCoversProvider),
          builder: (context, shadeCovers, stage) => Positioned.fill(
            child: Offstage(
              offstage: shadeOccludes && shadeCovers,
              child: stage,
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(top: topInset),
            child: MobilePrimaryWindowStage(
              currentWindow: window,
              behind: visual.behind,
              opacity: hidden ? 0.0 : 1.0,
            ),
          ),
        );
      },
    );
  }
}

class MobileAppDeckLayer extends ConsumerWidget {
  const MobileAppDeckLayer({
    super.key,
    this.backdrop,
    required this.onPresentationChanged,
    this.onProgressChanged,
  });

  /// The scene behind recents, frosted once for its translucent cards.
  final ValueListenable<FrostedBackdrop?>? backdrop;
  final ValueChanged<bool> onPresentationChanged;
  final ValueChanged<double>? onProgressChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(
      referenceShellProvider.select((state) => state.overviewVisible),
    );
    final controller = ref.read(referenceShellProvider.notifier);
    final deskBeside = ref.watch(phoneDeskProvider) != null;
    return AppDeckLayer(
      deck: controller.deck,
      // The phone's apps; beside a desk the desk's stay off the deck.
      windows: ref.watch(
        referenceShellProvider.select((state) => state.openAppWindows),
      ),
      recents: recents,
      backdrop: backdrop,
      onPresentationChanged: onPresentationChanged,
      onProgressChanged: onProgressChanged,
      onCloseRecents: controller.closeOverview,
      onDismissWindow: controller.dismissFromRecents,
      onOpenWindow: controller.openFromRecents,
      onMoveWindowToDesk: deskBeside ? controller.moveToDesk : null,
    );
  }
}
