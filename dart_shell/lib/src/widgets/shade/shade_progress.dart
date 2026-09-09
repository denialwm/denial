import 'package:flutter/animation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shares the shade's painted progress, including its release spring, with
/// sibling shell layers. Listening to the animation does not rebuild providers.
final shadeProgressProvider = Provider<ProxyAnimation>((ref) {
  final progress = ProxyAnimation();
  ref.onDispose(() => progress.parent = null);
  return progress;
});
