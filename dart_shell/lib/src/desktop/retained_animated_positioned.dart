import 'package:flutter/widgets.dart';

/// Animates a positioned rectangle while retaining its child layout.
///
/// By default the child adopts the destination layout once. Supplying
/// [layoutRect] keeps a stable canonical layout instead, which lets callers
/// move and scale expensive retained layers without resizing them. A paint
/// transform maps that layout onto the interpolated visual rectangle and hit
/// testing follows the transform. Set [layoutDuringAnimation] when the child
/// really must be laid out at every intermediate rectangle.
class RetainedAnimatedPositioned extends ImplicitlyAnimatedWidget {
  const RetainedAnimatedPositioned({
    required this.rect,
    required this.child,
    this.layoutRect,
    this.animationOrigin,
    this.layoutDuringAnimation = false,
    required super.duration,
    super.curve,
    super.onEnd,
    super.key,
  });

  final Rect rect;
  final Widget child;
  final Rect? layoutRect;

  /// Overrides the visual begin rectangle when [rect] changes.
  ///
  /// This is useful when a retained child had a temporary paint transform:
  /// the transform can be removed while its absolute visual rectangle becomes
  /// the position tween's origin, avoiding a one-frame snap.
  final Rect? animationOrigin;
  final bool layoutDuringAnimation;

  @override
  AnimatedWidgetBaseState<RetainedAnimatedPositioned> createState() =>
      _RetainedAnimatedPositionedState();
}

class _RetainedAnimatedPositionedState
    extends AnimatedWidgetBaseState<RetainedAnimatedPositioned> {
  RectTween? _rect;

  @override
  void didUpdateWidget(covariant RetainedAnimatedPositioned oldWidget) {
    final origin = widget.animationOrigin;
    if (origin != null && origin != oldWidget.animationOrigin) {
      // Make the presentation origin the tween's current value. This also
      // starts a return animation when the authoritative destination equals
      // the pre-drag rectangle.
      _rect = RectTween(begin: origin, end: origin);
    }
    super.didUpdateWidget(oldWidget);
  }

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
    final retainedRect = widget.layoutRect ?? destinationRect;
    final layoutRect = widget.layoutDuringAnimation ? visualRect : retainedRect;
    final scaleX = retainedRect.width > 0
        ? visualRect.width / retainedRect.width
        : 1.0;
    final scaleY = retainedRect.height > 0
        ? visualRect.height / retainedRect.height
        : 1.0;
    final translation = visualRect.topLeft - retainedRect.topLeft;
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
