import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../localization/denial_localizations.dart';

class OverviewScrim extends StatelessWidget {
  const OverviewScrim({
    super.key,
    required this.progress,
    this.fadingOut = false,
    required this.onTap,
  });

  final Animation<double> progress;
  final bool fadingOut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scrim = context.shellColors.overviewScrim;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: progress,
          child: AnimatedOpacity(
            opacity: fadingOut ? 0 : 1,
            duration: Motion.focusZoom,
            curve: Motion.standard,
            child: ColoredBox(color: scrim.withValues(alpha: scrim.a * 0.5)),
          ),
        ),
      ),
    );
  }
}

class EmptyOverviewState extends StatelessWidget {
  const EmptyOverviewState({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final intro = Motion.standard.transform(progress);
    return Center(
      child: Transform.translate(
        offset: Offset(0, lerpDouble(28.0, 0.0, intro)!),
        child: Opacity(
          opacity: unit(progress * 1.3),
          child: Text(
            context.l10n.overviewNoWindows,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.shellColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
