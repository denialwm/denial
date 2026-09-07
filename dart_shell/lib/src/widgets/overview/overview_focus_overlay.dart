import 'package:flutter/widgets.dart';

import '../../models/denial_window.dart';
import '../../theme/shell_theme.dart';
import '../window_hero.dart';
import '../retained_window_motion.dart';
import '../../theme/motion.dart';

/// Morphs a tapped overview card back to full screen before focusing it.
class OverviewFocusOverlay extends StatelessWidget {
  const OverviewFocusOverlay({
    super.key,
    required this.controller,
    required this.window,
    required this.startRect,
  });

  final AnimationController controller;
  final DenialWindow window;
  final Rect startRect;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: RetainedWindowMotion(
          progress: controller,
          begin: startRect,
          end: Offset.zero & MediaQuery.sizeOf(context),
          beginRadius: context.shellTheme.windowRadius,
          curve: Motion.standard,
          child: WindowSurface(window: window),
        ),
      ),
    );
  }
}
