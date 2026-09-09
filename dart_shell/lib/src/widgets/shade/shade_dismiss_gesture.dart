import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/shell_controller.dart';
import '../../input/input_layout.dart';

/// Shares the handle's interactive panel motion with the space below it.
/// A scrollable child wins the vertical gesture arena; [canDrag] also guards
/// against dismissing a long history when its scroll position is at an edge.
class ShadeDismissGesture extends ConsumerStatefulWidget {
  const ShadeDismissGesture({
    required this.progress,
    required this.child,
    this.canDrag,
    super.key,
  });

  final Animation<double> progress;
  final Widget child;
  final bool Function()? canDrag;

  @override
  ConsumerState<ShadeDismissGesture> createState() =>
      _ShadeDismissGestureState();
}

class _ShadeDismissGestureState extends ConsumerState<ShadeDismissGesture> {
  bool _dragging = false;
  double _distance = 0;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(shellControllerProvider.notifier);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.closeQuickSettings,
      onVerticalDragStart: (_) {
        _dragging = widget.canDrag?.call() ?? true;
        _distance = 0;
        if (_dragging) {
          controller.startQuickSettingsDrag(progress: widget.progress.value);
        }
      },
      onVerticalDragUpdate: (details) {
        if (!_dragging) return;
        _distance += details.delta.dy;
        controller.updateQuickSettingsDrag(
          Offset(
            0,
            details.delta.dy *
                ShellMetrics.quickSettingsDragScale(MediaQuery.sizeOf(context)),
          ),
        );
      },
      onVerticalDragEnd: (details) {
        if (!_dragging) return;
        _dragging = false;
        final velocity = details.primaryVelocity ?? 0;
        if (_distance <= -48 || velocity <= -500) {
          controller.closeQuickSettings();
        } else {
          controller.endQuickSettingsDrag(velocity);
        }
      },
      onVerticalDragCancel: () {
        if (!_dragging) return;
        _dragging = false;
        controller.endQuickSettingsDrag(0);
      },
      child: widget.child,
    );
  }
}
