import 'package:flutter/widgets.dart';

/// Animates a positioned rectangle, retaining its child layout by default.
///
/// The child adopts the destination layout once. A paint transform maps that
/// retained layout onto the interpolated visual rectangle until the animation
/// completes. Set [layoutDuringAnimation] when layout-dependent visuals such as
/// shadows must follow every intermediate rectangle instead. Hit testing
/// follows either path.
class RetainedAnimatedPositioned extends ImplicitlyAnimatedWidget {
  const RetainedAnimatedPositioned({
    required this.rect,
    required this.child,
    this.layoutDuringAnimation = false,
    required super.duration,
    super.curve,
    super.onEnd,
    super.key,
  });

  final Rect rect;
  final Widget child;
  final bool layoutDuringAnimation;

  @override
  AnimatedWidgetBaseState<RetainedAnimatedPositioned> createState() =>
      _RetainedAnimatedPositionedState();
}

class _RetainedAnimatedPositionedState
    extends AnimatedWidgetBaseState<RetainedAnimatedPositioned> {
  RectTween? _rect;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _rect =
        visitor(_rect, widget.rect, (value) => RectTween(begin: value as Rect))
            as RectTween?;
  }

  @override
  Widget build(BuildContext context) {
    final destinationRect = widget.rect;
    final visualRect = _rect?.evaluate(animation) ?? destinationRect;
    final layoutRect = widget.layoutDuringAnimation
        ? visualRect
        : destinationRect;
    final scaleX = destinationRect.width > 0
        ? visualRect.width / destinationRect.width
        : 1.0;
    final scaleY = destinationRect.height > 0
        ? visualRect.height / destinationRect.height
        : 1.0;
    final translation = visualRect.topLeft - destinationRect.topLeft;
    final transform = widget.layoutDuringAnimation
        ? Matrix4.identity()
        : (Matrix4.diagonal3Values(scaleX, scaleY, 1)
            ..setTranslationRaw(translation.dx, translation.dy, 0));

    return Positioned.fromRect(
      rect: layoutRect,
      child: Transform(
        transform: transform,
        transformHitTests: true,
        child: widget.child,
      ),
    );
  }
}
