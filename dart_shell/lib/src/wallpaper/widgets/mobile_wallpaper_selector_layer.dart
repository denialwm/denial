import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../input/shell_interaction_registry.dart';
import '../../state/display_layout.dart';
import '../../theme/motion.dart';
import '../../widgets/edge_panel_layer.dart';
import '../../widgets/shell_wallpaper.dart';
import '../state/wallpaper_controller.dart';
import 'mobile_wallpaper_selector_surface.dart';

/// Presents the shared wallpaper experience above the complete mobile shell.
///
/// The wallpaper plane intentionally covers the running application while the
/// selector is open, matching the desktop experience without changing the
/// mobile application or launcher scene underneath it.
class MobileWallpaperSelectorLayer extends ConsumerWidget {
  const MobileWallpaperSelectorLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(
      wallpaperControllerProvider.select((state) => state.selectorVisible),
    );
    final displayLayout = ref.watch(displayLayoutProvider);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion ? Duration.zero : Motion.wallpaperSelector;
    return TextFieldTapRegion(
      child: Listener(
        // Full-scene ownership must also exist in Flutter's hit-test tree.
        // Otherwise blank selector areas fall through to the shell gestures
        // underneath, which can dismiss the system keyboard.
        behavior: visible
            ? HitTestBehavior.opaque
            : HitTestBehavior.deferToChild,
        child: MobileKeyboardViewport(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final canvas = Offset.zero & constraints.biggest;
              final requestedRect = displayLayout?.mainOutput?.logicalRect
                  .intersect(canvas);
              final displayRect = requestedRect == null || requestedRect.isEmpty
                  ? canvas
                  : requestedRect;
              return ShellInputRegion(
                debugLabel: 'Mobile wallpaper selector',
                active: visible,
                pointerPolicy: ShellPointerPolicy.fullScene,
                keyboardPolicy: ShellKeyboardPolicy.capture,
                compositorPolicy: ShellCompositorPolicy.exclusive,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: duration,
                        switchInCurve: Motion.md3EmphasizedDecelerate,
                        switchOutCurve: Motion.md3EmphasizedAccelerate,
                        child: visible
                            ? const ShellWallpaper(
                                key: ValueKey<String>(
                                  'mobile-wallpaper-selector-backdrop',
                                ),
                              )
                            : const SizedBox.expand(
                                key: ValueKey<String>(
                                  'mobile-wallpaper-selector-backdrop-hidden',
                                ),
                              ),
                      ),
                    ),
                    IgnorePointer(
                      ignoring: !visible,
                      child: AnimatedSwitcher(
                        duration: duration,
                        switchInCurve: Motion.md3EmphasizedDecelerate,
                        switchOutCurve: Motion.md3EmphasizedAccelerate,
                        child: visible
                            ? Stack(
                                key: const ValueKey<String>(
                                  'mobile-wallpaper-selector-visible',
                                ),
                                fit: StackFit.expand,
                                children: [
                                  Positioned.fromRect(
                                    rect: displayRect,
                                    child: MobileWallpaperSelectorSurface(
                                      displaySize: displayRect.size,
                                      onDismiss: ref
                                          .read(
                                            wallpaperControllerProvider
                                                .notifier,
                                          )
                                          .closeSelector,
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.expand(
                                key: ValueKey<String>(
                                  'mobile-wallpaper-selector-hidden',
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
