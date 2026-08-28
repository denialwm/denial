import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

/// Renders the focused mobile surface and its horizontal app-switch target.
class MobilePrimaryWindowStage extends StatelessWidget {
  const MobilePrimaryWindowStage({
    super.key,
    required this.currentWindow,
    required this.switchTargetWindow,
    required this.switchDragX,
    required this.opacity,
  });

  final DenialWindow currentWindow;
  final DenialWindow? switchTargetWindow;
  final double switchDragX;
  final double opacity;

  static const double _switchGap = ShellMetrics.appSwitchGap;

  @override
  Widget build(BuildContext context) {
    final switchRadius = context.shellTheme.borderRadius(18);
    final target = switchTargetWindow;
    if (target == null || switchDragX.abs() < 0.5) {
      final texture = WindowContentRect(
        key: ValueKey<int>(currentWindow.objectId),
        window: currentWindow,
        active: true,
      );
      return opacity >= 1.0
          ? texture
          : Opacity(opacity: opacity, child: texture);
    }

    final switchStage = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final travel = width + _switchGap;
        final dx = switchDragX.clamp(-travel, travel).toDouble();
        final targetDx = dx > 0.0
            ? dx - width - _switchGap
            : dx + width + _switchGap;

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(dx, 0.0),
                child: WindowContentRect(
                  key: ValueKey<int>(currentWindow.objectId),
                  window: currentWindow,
                  active: true,
                  borderRadius: switchRadius,
                ),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(targetDx, 0.0),
                child: WindowContentRect(
                  key: ValueKey<int>(target.objectId),
                  window: target,
                  borderRadius: switchRadius,
                ),
              ),
            ),
          ],
        );
      },
    );
    return opacity >= 1.0
        ? switchStage
        : Opacity(opacity: opacity, child: switchStage);
  }
}
