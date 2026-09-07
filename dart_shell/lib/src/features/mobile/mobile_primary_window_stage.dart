import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../widgets/retained_translation.dart';

/// Keeps both app subtrees laid out while the switch gesture moves their layers.
class MobilePrimaryWindowStage extends StatefulWidget {
  const MobilePrimaryWindowStage({
    super.key,
    required this.currentWindow,
    required this.switchTargetWindow,
    required this.switchDragX,
    required this.opacity,
  });

  final DenialWindow currentWindow;
  final DenialWindow? switchTargetWindow;
  final ValueListenable<double> switchDragX;
  final double opacity;

  @override
  State<MobilePrimaryWindowStage> createState() =>
      _MobilePrimaryWindowStageState();
}

class _MobilePrimaryWindowStageState extends State<MobilePrimaryWindowStage> {
  final _currentTranslation = ValueNotifier(Offset.zero);
  final _targetTranslation = ValueNotifier(Offset.zero);
  double _width = 0;

  @override
  void initState() {
    super.initState();
    widget.switchDragX.addListener(_updateTranslations);
  }

  @override
  void didUpdateWidget(covariant MobilePrimaryWindowStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.switchDragX != widget.switchDragX) {
      oldWidget.switchDragX.removeListener(_updateTranslations);
      widget.switchDragX.addListener(_updateTranslations);
    }
    _updateTranslations();
  }

  @override
  void dispose() {
    widget.switchDragX.removeListener(_updateTranslations);
    _currentTranslation.dispose();
    _targetTranslation.dispose();
    super.dispose();
  }

  void _updateTranslations() {
    final travel = _width + ShellMetrics.appSwitchGap;
    final dx = widget.switchDragX.value.clamp(-travel, travel).toDouble();
    _currentTranslation.value = Offset(dx, 0);
    _targetTranslation.value = Offset(dx > 0 ? dx - travel : dx + travel, 0);
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.switchTargetWindow;
    final radius = target == null
        ? BorderRadius.zero
        : context.shellTheme.borderRadius(18);
    final current = WindowContentRect(
      key: ValueKey<int>(widget.currentWindow.objectId),
      window: widget.currentWindow,
      active: true,
      borderRadius: radius,
    );
    final stage = target == null
        ? current
        : LayoutBuilder(
            builder: (context, constraints) {
              _width = constraints.maxWidth;
              _updateTranslations();
              return Stack(
                fit: StackFit.expand,
                children: [
                  RetainedTranslation(
                    translation: _currentTranslation,
                    child: current,
                  ),
                  RetainedTranslation(
                    translation: _targetTranslation,
                    child: WindowContentRect(
                      key: ValueKey<int>(target.objectId),
                      window: target,
                      borderRadius: radius,
                    ),
                  ),
                ],
              );
            },
          );
    // Keep the surface and its backdrop mounted while the overview hero owns
    // presentation. Inserting/removing this wrapper recreates the whole app
    // subtree on gesture cancellation, including a transparent app's glass.
    return Opacity(opacity: widget.opacity, child: stage);
  }
}
