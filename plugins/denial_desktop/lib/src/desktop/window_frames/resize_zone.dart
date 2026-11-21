import 'package:denial_flutter_sdk/rendering.dart' show ShellMouseCursors;
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A strip where a press resizes [window] from [edge]: the primary mouse
/// button or a finger, which the compositor takes over.
class ResizeZone extends ConsumerWidget {
  const ResizeZone({
    required this.window,
    required this.edge,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    super.key,
  });

  final DenialWindow window;
  final DenialWindowResizeEdge edge;
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
  final double? width;
  final double? height;

  MouseCursor get _cursor => switch (edge) {
    DenialWindowResizeEdge.top ||
    DenialWindowResizeEdge.bottom => ShellMouseCursors.verticalResize,
    DenialWindowResizeEdge.left ||
    DenialWindowResizeEdge.right => ShellMouseCursors.horizontalResize,
    DenialWindowResizeEdge.topLeft ||
    DenialWindowResizeEdge.bottomRight => ShellMouseCursors.diagonalNwSeResize,
    DenialWindowResizeEdge.topRight ||
    DenialWindowResizeEdge.bottomLeft => ShellMouseCursors.diagonalNeSwResize,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: _cursor,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.kind == PointerDeviceKind.mouse &&
                event.buttons != kPrimaryMouseButton) {
              return;
            }
            ref.read(denialBridgeProvider).beginWindowResize(window, edge);
          },
        ),
      ),
    );
  }
}
