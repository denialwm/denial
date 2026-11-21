import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter/widgets.dart';

import 'resize_zone.dart';

/// The invisible band around a window where a press resizes it: wide enough
/// for a finger, as the border itself is not.
class WindowsFrameReach extends StatelessWidget {
  const WindowsFrameReach({required this.frame, super.key});

  /// How far along an edge a corner reaches, past the band.
  static const _corner = 20.0;

  final ShellWindowFrameContext frame;

  @override
  Widget build(BuildContext context) {
    final window = frame.window;
    final reach = frame.reach;
    // Corners come last, over the edges they join. Only the band itself is
    // hit, so each corner is the two arms outside the frame.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (reach.top > 0.0)
          ResizeZone(
            window: window,
            edge: DenialWindowResizeEdge.top,
            left: 0.0,
            top: 0.0,
            right: 0.0,
            height: reach.top,
          ),
        if (reach.bottom > 0.0)
          ResizeZone(
            window: window,
            edge: DenialWindowResizeEdge.bottom,
            left: 0.0,
            right: 0.0,
            bottom: 0.0,
            height: reach.bottom,
          ),
        if (reach.left > 0.0)
          ResizeZone(
            window: window,
            edge: DenialWindowResizeEdge.left,
            left: 0.0,
            top: 0.0,
            bottom: 0.0,
            width: reach.left,
          ),
        if (reach.right > 0.0)
          ResizeZone(
            window: window,
            edge: DenialWindowResizeEdge.right,
            top: 0.0,
            right: 0.0,
            bottom: 0.0,
            width: reach.right,
          ),
        ResizeZone(
          window: window,
          edge: DenialWindowResizeEdge.topLeft,
          left: 0.0,
          top: 0.0,
          width: reach.left + _corner,
          height: reach.top + _corner,
        ),
        ResizeZone(
          window: window,
          edge: DenialWindowResizeEdge.topRight,
          top: 0.0,
          right: 0.0,
          width: reach.right + _corner,
          height: reach.top + _corner,
        ),
        ResizeZone(
          window: window,
          edge: DenialWindowResizeEdge.bottomLeft,
          left: 0.0,
          bottom: 0.0,
          width: reach.left + _corner,
          height: reach.bottom + _corner,
        ),
        ResizeZone(
          window: window,
          edge: DenialWindowResizeEdge.bottomRight,
          right: 0.0,
          bottom: 0.0,
          width: reach.right + _corner,
          height: reach.bottom + _corner,
        ),
      ],
    );
  }
}
