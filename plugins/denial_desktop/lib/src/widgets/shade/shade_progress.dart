import 'package:denial_flutter_sdk/motion.dart' show SelectedListenable;
import 'package:denial_flutter_sdk/rendering.dart' show WindowBackdropCache;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shade_expansion_motion.dart';

/// Shares the shade's painted progress, including its release spring, with
/// sibling shell layers. Listening to the animation does not rebuild providers.
final shadeProgressProvider = Provider<ProxyAnimation>((ref) {
  final progress = ProxyAnimation();
  ref.onDispose(() => progress.parent = null);
  return progress;
});

/// Whether the shade's material is fully established over the scene, from a
/// third of its travel on, open or moving. It notifies only when that
/// changes, not on every frame of the shade's motion.
final shadeCoversProvider = Provider<ValueListenable<bool>>((ref) {
  final progress = ref.watch(shadeProgressProvider);
  final covers = SelectedListenable(
    progress,
    () => ColorOsShadeMotion.blurFraction(progress.value) >= 1.0,
  );
  ref.onDispose(covers.dispose);
  return covers;
});

/// The shade's material is the opaque frost, which hides the scene beneath
/// it while [shadeCoversProvider] holds. Live material samples that scene.
bool shadeFrostOccludes(BuildContext context) =>
    context.shellTheme.effectivePanelOpacity < 1 &&
    WindowBackdropCache.maybeOf(context) != null;
