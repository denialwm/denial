import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart';

/// A white flash and a haptic pulse when deniald has captured a screenshot
/// (Power plus Volume Down). The pixels are taken before the flash draws.
class MobileScreenshotFlash extends ConsumerStatefulWidget {
  const MobileScreenshotFlash({super.key});

  @override
  ConsumerState<MobileScreenshotFlash> createState() =>
      _MobileScreenshotFlashState();
}

class _MobileScreenshotFlashState extends ConsumerState<MobileScreenshotFlash>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 320);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// Up fast, down slower, like a shutter.
  late final Animation<double> _alpha = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.0,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 15,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 0.0,
      ).chain(CurveTween(curve: Curves.easeIn)),
      weight: 85,
    ),
  ]).animate(_controller);

  late final StreamSubscription<DenialShellActionEvent> _shellActions;

  @override
  void initState() {
    super.initState();
    _shellActions = ref.read(denialBridgeProvider).shellActions.listen((event) {
      if (event.action != DenialShellAction.screenshotCaptured) return;
      ref.read(hapticsServiceProvider).pulse();
      _controller.forward(from: 0);
    });
    _controller.addStatusListener((_) => setState(() {}));
  }

  @override
  void dispose() {
    unawaited(_shellActions.cancel());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.isAnimating) return const SizedBox.shrink();
    // Reduced motion keeps a softer flash: still feedback, less glare.
    final peak = MediaQuery.disableAnimationsOf(context) ? 0.35 : 0.8;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _alpha,
        // Fade the colour, not an Opacity layer: no offscreen target.
        builder: (context, _) => ColoredBox(
          color: const Color(0xFFFFFFFF).withValues(alpha: _alpha.value * peak),
        ),
      ),
    );
  }
}
