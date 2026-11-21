import 'package:flutter/widgets.dart';

/// Lays [child] out in the shell's own units and draws it [scale] times as
/// large, filling the box it is given.
///
/// The child sees a box [scale] times smaller and a [MediaQuery] to match:
/// its size, padding and insets divided by [scale], and a device pixel ratio
/// [scale] times larger, so what it snaps to whole pixels stays on them.
/// Pointers reach it through the same transform, and the input regions it
/// reports through [RenderBox.getTransformTo] are where it is drawn.
class ShellScaleViewport extends StatelessWidget {
  const ShellScaleViewport({
    super.key,
    required this.scale,
    this.clip = false,
    required this.child,
  });

  final double scale;

  /// Whether to clip what the child draws past the box.
  final bool clip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = this.scale;
    if (scale == 1.0 || !scale.isFinite || scale <= 0.0) {
      return child;
    }
    final Widget result = LayoutBuilder(
      builder: (context, constraints) {
        // Only a box of known size can be filled.
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final media = MediaQuery.of(context);
        final size = constraints.biggest;
        final shellSize = Size(size.width / scale, size.height / scale);
        return OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: shellSize,
              child: MediaQuery(
                data: shellScaleMediaQuery(media, shellSize, scale),
                child: child,
              ),
            ),
          ),
        );
      },
    );
    return clip ? ClipRect(child: result) : result;
  }
}

/// [media] as a child of a [ShellScaleViewport] of [scale] sees it, in a
/// box of [size].
MediaQueryData shellScaleMediaQuery(
  MediaQueryData media,
  Size size,
  double scale,
) {
  EdgeInsets divide(EdgeInsets insets) => insets / scale;
  return media.copyWith(
    size: size,
    devicePixelRatio: media.devicePixelRatio * scale,
    padding: divide(media.padding),
    viewPadding: divide(media.viewPadding),
    viewInsets: divide(media.viewInsets),
    systemGestureInsets: divide(media.systemGestureInsets),
  );
}
