import 'package:flutter/widgets.dart';

import '../theme/motion.dart';
import '../widgets/shell_cursor.dart';

/// Pointer interaction for a window preview in the desktop overview.
///
/// Overview previews retain the window's real layout size and use a paint
/// transform to fit it into the arranged overview frame. Pan deltas therefore
/// have to be measured in global coordinates: Flutter's local [DragUpdateDetails.delta]
/// is transformed back through the preview scale and would make a scaled-down
/// window move farther than the pointer.
class DesktopOverviewPreviewInteraction extends StatefulWidget {
  const DesktopOverviewPreviewInteraction({
    super.key,
    required this.overviewActive,
    required this.overview,
    required this.desktopWidget,
    required this.dragging,
    required this.label,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.child,
  });

  final bool overviewActive;
  final bool overview;
  final bool desktopWidget;
  final bool dragging;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  final Widget child;

  @override
  State<DesktopOverviewPreviewInteraction> createState() =>
      _DesktopOverviewPreviewInteractionState();
}

class _DesktopOverviewPreviewInteractionState
    extends State<DesktopOverviewPreviewInteraction> {
  static const double _hoverScale = 1.025;

  bool _hovered = false;
  Offset? _lastGlobalDragPosition;

  @override
  void didUpdateWidget(covariant DesktopOverviewPreviewInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.overview && !widget.desktopWidget) || widget.dragging) {
      _hovered = false;
    }
    if (!widget.overview) {
      _lastGlobalDragPosition = null;
    }
  }

  void _setHovered(bool hovered) {
    if ((!widget.overview && !widget.desktopWidget) || _hovered == hovered) {
      return;
    }
    setState(() => _hovered = hovered);
  }

  void _startDrag(DragStartDetails details) {
    _lastGlobalDragPosition = details.globalPosition;
    widget.onDragStart();
  }

  void _updateDrag(DragUpdateDetails details) {
    final previousPosition = _lastGlobalDragPosition;
    final globalPosition = details.globalPosition;
    _lastGlobalDragPosition = globalPosition;
    if (previousPosition != null) {
      widget.onDragUpdate(globalPosition - previousPosition);
    }
  }

  void _endDrag() {
    _lastGlobalDragPosition = null;
    widget.onDragEnd();
  }

  void _cancelDrag() {
    _lastGlobalDragPosition = null;
    widget.onDragCancel();
  }

  @override
  Widget build(BuildContext context) {
    final hovered =
        (widget.overview || widget.desktopWidget) &&
        !widget.dragging &&
        _hovered;
    final interactive =
        (widget.overviewActive && widget.overview) ||
        (!widget.overviewActive && widget.desktopWidget);
    return Semantics(
      button: interactive,
      label: interactive ? widget.label : null,
      child: MouseRegion(
        cursor: interactive ? ShellMouseCursors.link : ShellMouseCursors.normal,
        onEnter: interactive ? (_) => _setHovered(true) : null,
        onExit: interactive ? (_) => _setHovered(false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: interactive ? widget.onTap : null,
          onPanStart: widget.overview ? _startDrag : null,
          onPanUpdate: widget.overview ? _updateDrag : null,
          onPanEnd: widget.overview ? (_) => _endDrag() : null,
          onPanCancel: widget.overview ? _cancelDrag : null,
          child: AnimatedScale(
            duration: Motion.tile,
            curve: hovered
                ? Motion.md3EmphasizedDecelerate
                : Motion.md3EmphasizedAccelerate,
            scale: hovered
                ? widget.desktopWidget
                      ? 1.018
                      : _hoverScale
                : 1.0,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
