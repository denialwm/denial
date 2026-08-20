import 'package:flutter/widgets.dart';

/// Animates a positioned rectangle without relaying out its child every tick.
///
/// The child adopts the destination layout once. A paint transform maps that
/// retained layout onto the interpolated visual rectangle until the animation
/// completes. Hit testing follows the same transform.
class RetainedAnimatedPositioned extends ImplicitlyAnimatedWidget {
  const RetainedAnimatedPositioned({
    required this.rect,
    required this.child,
    required super.duration,
    super.curve,
    super.onEnd,
    super.key,
  });

  final Rect rect;
  final Widget child;

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
    final layoutRect = widget.rect;
    final visualRect = _rect?.evaluate(animation) ?? layoutRect;
    final scaleX = layoutRect.width > 0
        ? visualRect.width / layoutRect.width
        : 1.0;
    final scaleY = layoutRect.height > 0
        ? visualRect.height / layoutRect.height
        : 1.0;
    final translation = visualRect.topLeft - layoutRect.topLeft;
    final transform = Matrix4.diagonal3Values(scaleX, scaleY, 1)
      ..setTranslationRaw(translation.dx, translation.dy, 0);

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
