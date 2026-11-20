import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import '../widgets/desktop_visibility_transition.dart';
import 'desktop_plugin_window_frame.dart';

/// Publishes whether a window has finished moving into overview.
///
/// The position animation owns this signal so preview emphasis follows its
/// actual completion rather than a parallel timer that can drift or ignore an
/// interrupted transition.
class DesktopOverviewTransitionStatus
    extends InheritedNotifier<ValueNotifier<bool>> {
  const DesktopOverviewTransitionStatus({
    super.key,
    required ValueNotifier<bool> completed,
    required super.child,
  }) : super(notifier: completed);

  static bool completedOf(BuildContext context) {
    final status = context
        .dependOnInheritedWidgetOfExactType<DesktopOverviewTransitionStatus>();
    return status?.notifier?.value ?? true;
  }
}

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
    required this.compositorRoutesInput,
    this.shellFrameMargins,
    required this.overviewActive,
    required this.overview,
    required this.desktopWidget,
    required this.dragging,
    this.selected = false,
    this.previewScale = 1.0,
    required this.label,
    required this.onTap,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.child,
  });

  /// The compositor hands this window's input to the client itself, by its
  /// surfaces and their input regions. Only what no client takes, such as a
  /// click through a desktop pet's transparent part, reaches the shell.
  final bool compositorRoutesInput;

  /// The sides of the window where a plugin's frame takes the pointer. The
  /// compositor gives those to the shell, so they are not let through.
  final EdgeInsets? shellFrameMargins;
  final bool overviewActive;
  final bool overview;
  final bool desktopWidget;
  final bool dragging;
  final bool selected;

  /// How much the overview shrinks the window: the selection ring is drawn
  /// inside the window, so its width is divided by this to stay four logical
  /// pixels wide on screen.
  final double previewScale;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onClose;
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
  static const double _emphasizedScale = 1.018;
  static const double _selectionRingWidth = 4.0;

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

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.overviewActive &&
        widget.overview &&
        event.buttons == kMiddleMouseButton) {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final overviewTransitionCompleted =
        DesktopOverviewTransitionStatus.completedOf(context);
    final hovered =
        (widget.overview || widget.desktopWidget) &&
        !widget.dragging &&
        _hovered;
    final emphasized = widget.overview
        ? overviewTransitionCompleted && (widget.selected || hovered)
        : hovered;
    final interactive =
        (widget.overviewActive && widget.overview) ||
        (!widget.overviewActive && widget.desktopWidget);
    // Outside the overview a client window's preview has nothing to do with
    // the pointer. Whatever reaches the shell inside it belongs to the shell
    // below, such as the top bar under a window that lets clicks through.
    return DesktopFrameMarginsHitTest(
      enabled: widget.compositorRoutesInput && !interactive,
      margins: widget.shellFrameMargins,
      child: _preview(context, interactive, emphasized),
    );
  }

  Widget _preview(BuildContext context, bool interactive, bool emphasized) {
    return Semantics(
      button: interactive,
      selected: widget.overview ? widget.selected : null,
      label: interactive ? widget.label : null,
      child: MouseRegion(
        cursor: interactive ? ShellMouseCursors.link : ShellMouseCursors.normal,
        onEnter: interactive ? (_) => _setHovered(true) : null,
        onExit: interactive ? (_) => _setHovered(false) : null,
        child: Listener(
          onPointerDown: _handlePointerDown,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: interactive ? widget.onTap : null,
            onPanStart: widget.overview ? _startDrag : null,
            onPanUpdate: widget.overview ? _updateDrag : null,
            onPanEnd: widget.overview ? (_) => _endDrag() : null,
            onPanCancel: widget.overview ? _cancelDrag : null,
            child: AnimatedScale(
              duration: Motion.tile,
              curve: emphasized
                  ? Motion.md3EmphasizedDecelerate
                  : Motion.md3EmphasizedAccelerate,
              scale: emphasized ? _emphasizedScale : 1.0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.child,
                  IgnorePointer(
                    child: DesktopVisibilityFade(
                      child: AnimatedContainer(
                        duration: Motion.tile,
                        curve: Motion.standard,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: context.shellTheme.accent.withValues(
                              alpha: widget.selected ? 1.0 : 0.0,
                            ),
                            width: widget.selected
                                ? _selectionRingWidth /
                                      widget.previewScale.clamp(0.05, 4.0)
                                : 0.0,
                          ),
                          borderRadius: BorderRadius.circular(
                            context.shellTheme.windowRadius,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How much a window laid out in [layout] is shrunk to show in [shown].
double desktopPreviewScale(Rect shown, Rect layout) {
  if (layout.width <= 0 || layout.height <= 0) return 1.0;
  final scale = shown.width / layout.width;
  final vertical = shown.height / layout.height;
  return scale < vertical ? scale : vertical;
}
