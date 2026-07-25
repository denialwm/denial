import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../input/input_layout.dart';
import '../../localization/denial_localizations.dart';
import '../../state/shell_controller.dart';
import '../../state/system_status.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import 'status_glyphs.dart';

/// The always-on top status bar. Dragging it down opens the quick-settings
/// shade. Time and battery are isolated into their own consumers so their
/// periodic updates never rebuild the drag surface.
class ShadeStatusBar extends ConsumerWidget {
  const ShadeStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final topPadding = MediaQuery.paddingOf(context).top;
    final statusColorArgb = ref.watch(
      shellControllerProvider.select(
        (state) => state.foregroundWindow?.statusColorArgb,
      ),
    );
    final forceWhiteForeground = ref.watch(
      shellControllerProvider.select(
        (state) =>
            state.overviewVisible ||
            state.launchTransitionActive ||
            state.gestureDrag.dy < 0.0 ||
            state.homeTransitionActive,
      ),
    );
    final foreground = forceWhiteForeground
        ? const Color(0xffffffff)
        : _statusForegroundFor(statusColorArgb);

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: topPadding + ShellMetrics.statusBarHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => controller.startQuickSettingsDrag(),
        onVerticalDragUpdate: (details) {
          controller.updateQuickSettingsDrag(Offset(0.0, details.delta.dy));
        },
        onVerticalDragEnd: (details) {
          controller.endQuickSettingsDrag(details.primaryVelocity ?? 0.0);
        },
        onVerticalDragCancel: () => controller.endQuickSettingsDrag(0.0),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, topPadding + 10, 20, 8),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: foreground),
            duration: Motion.cardSettle,
            curve: Motion.standard,
            builder: (context, animatedForeground, _) {
              final color = animatedForeground ?? foreground;
              return Row(
                children: [
                  _StatusClock(color: color),
                  const Spacer(),
                  _StatusCluster(color: color),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StatusClock extends ConsumerWidget {
  const _StatusClock({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    return Text(
      context.l10n.statusBarLiveTime(localizedTime(context, now)),
      style: ShellText.statusClock.copyWith(color: color),
    );
  }
}

class _StatusCluster extends ConsumerWidget {
  const _StatusCluster({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StatusCluster(battery: ref.watch(batteryProvider), color: color);
  }
}

Color _statusForegroundFor(int? statusColorArgb) {
  if (statusColorArgb == null) {
    return ShellColors.textPrimary;
  }

  final background = Color.alphaBlend(
    Color(statusColorArgb),
    ShellColors.background,
  );
  return background.computeLuminance() > 0.52
      ? const Color(0xff000000)
      : const Color(0xffffffff);
}
