import 'package:denial_flutter_sdk/input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class DesktopPanelEdgeTrigger extends StatelessWidget {
  const DesktopPanelEdgeTrigger({
    super.key,
    required this.onEnter,
    required this.onExit,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: MouseRegion(
        opaque: true,
        onEnter: (_) => onEnter(),
        onExit: (_) => onExit(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Opens a panel when a finger swipes in from [edge] across this strip.
///
/// Touch only: a mouse opens the panel by hovering its edge. Translucent, so
/// a mouse hover still reaches the hover trigger beneath.
class DesktopPanelEdgeSwipe extends StatefulWidget {
  const DesktopPanelEdgeSwipe({
    super.key,
    required this.edge,
    required this.onSwipe,
  });

  /// Inward travel that opens the panel.
  static const double openDistance = 40.0;

  final InputEdge edge;
  final VoidCallback onSwipe;

  @override
  State<DesktopPanelEdgeSwipe> createState() => _DesktopPanelEdgeSwipeState();
}

class _DesktopPanelEdgeSwipeState extends State<DesktopPanelEdgeSwipe> {
  static const _touch = <PointerDeviceKind>{PointerDeviceKind.touch};

  Offset? _start;

  void _begin(DragStartDetails details) {
    _start = details.globalPosition;
  }

  void _update(DragUpdateDetails details) {
    final start = _start;
    if (start == null) {
      return;
    }
    final travel = details.globalPosition - start;
    final inward = switch (widget.edge) {
      InputEdge.left => travel.dx,
      InputEdge.right => -travel.dx,
      InputEdge.top => travel.dy,
      InputEdge.bottom => -travel.dy,
    };
    if (inward >= DesktopPanelEdgeSwipe.openDistance) {
      _start = null;
      widget.onSwipe();
    }
  }

  void _end() {
    _start = null;
  }

  @override
  Widget build(BuildContext context) {
    final horizontal =
        widget.edge == InputEdge.left || widget.edge == InputEdge.right;
    return ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        supportedDevices: _touch,
        onHorizontalDragStart: horizontal ? _begin : null,
        onHorizontalDragUpdate: horizontal ? _update : null,
        onHorizontalDragEnd: horizontal ? (_) => _end() : null,
        onHorizontalDragCancel: horizontal ? _end : null,
        onVerticalDragStart: horizontal ? null : _begin,
        onVerticalDragUpdate: horizontal ? null : _update,
        onVerticalDragEnd: horizontal ? null : (_) => _end(),
        onVerticalDragCancel: horizontal ? null : _end,
        child: const SizedBox.expand(),
      ),
    );
  }
}

Offset desktopPanelEntryDirection(int horizontal, int vertical) {
  if (horizontal != 0) {
    return Offset(horizontal.toDouble(), 0);
  }
  if (vertical != 0) {
    return Offset(0, vertical.toDouble());
  }
  return Offset.zero;
}
