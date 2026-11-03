import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/rendering.dart';

class OverviewScrim extends StatelessWidget {
  const OverviewScrim({super.key, required this.opacity, required this.onTap});

  /// The scrim over the scene behind recents. Translucent cards draw it over
  /// their cached glass too, so it must match what they cover.
  static Color colorOf(BuildContext context) {
    final scrim = context.shellColors.overviewScrim;
    return scrim.withValues(alpha: scrim.a * 0.5);
  }

  final Animation<double> opacity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: opacity,
          child: ColoredBox(color: colorOf(context)),
        ),
      ),
    );
  }
}

class EmptyOverviewState extends StatelessWidget {
  const EmptyOverviewState({super.key, required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RetainedTranslation(
        translation: Tween<Offset>(
          begin: const Offset(0, 28),
          end: Offset.zero,
        ).chain(CurveTween(curve: Motion.standard)).animate(progress),
        child: FadeTransition(
          opacity: progress.drive(
            CurveTween(curve: const Interval(0, 1 / 1.3)),
          ),
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
