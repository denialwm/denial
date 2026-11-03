import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/motion.dart';

import '../../widgets/edge_panel_layer.dart';

import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import 'mobile_wallpaper_selector_surface.dart';
import '../../state/phone_desk.dart';

/// Presents the shared wallpaper experience above the complete mobile shell.
///
/// The wallpaper plane intentionally covers the running application while the
/// selector is open, matching the desktop experience without changing the
/// mobile application or launcher scene underneath it.
class MobileWallpaperSelectorLayer extends ConsumerStatefulWidget {
  const MobileWallpaperSelectorLayer({super.key});

  @override
  ConsumerState<MobileWallpaperSelectorLayer> createState() =>
      _MobileWallpaperSelectorLayerState();
}

class _MobileWallpaperSelectorLayerState
    extends ConsumerState<MobileWallpaperSelectorLayer> {
  late final StreamSubscription<DenialShellActionEvent> _shellActions;

  @override
  void initState() {
    super.initState();
    _shellActions = ref.read(denialBridgeProvider).shellActions.listen((event) {
      if (event.action == DenialShellAction.wallpaper) {
        unawaited(_openSelector());
      }
    });
  }

  Future<void> _openSelector() async {
    if (ref.read(referenceShellProvider).lockLayerVisible) return;
    var layout = ref.read(sceneDisplayLayoutProvider(ShellPart.of(context)));
    layout ??= await ref.read(displayLayoutProvider.notifier).ensureLoaded();
    // The profile may have changed or the session locked while loading outputs.
    if (!mounted || ref.read(referenceShellProvider).lockLayerVisible) return;
    final fallback =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    ref
        .read(wallpaperControllerProvider.notifier)
        .openSelector(targetPixelSize: layout?.pixelSize ?? fallback);
  }

  @override
  void dispose() {
    unawaited(_shellActions.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(
      wallpaperControllerProvider.select((state) => state.selectorVisible),
    );
    final displayLayout = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context)),
    );
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
