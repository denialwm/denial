import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

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
    this.globalClipRect,
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

  /// Keeps the retained child inside a stationary scene-space viewport.
  ///
  /// The clip is resolved against [layoutRect] on every animation tick, so it
  /// stays fixed while the child translates or scales underneath it.
  final Rect? globalClipRect;
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
    return Positioned.fill(
      child: _RetainedTransformBox(
        retainedSize: layoutRect.size,
        visualRect: visualRect,
        globalClipRect: widget.globalClipRect,
        child: widget.child,
      ),
    );
  }
}

/// Gives a retained child stable layout without constraining its painted or
/// interactive bounds to the old layout rectangle.
///
/// A normal [Transform] can paint outside its box, but ancestors reject hit
/// tests before the inverse transform is reached. Overview previews regularly
/// move outside their desktop rectangles, especially after a resize. This
/// scene-sized proxy owns the complete hit-test area, then applies one shared
/// transform to painting, hit testing, and semantics.
class _RetainedTransformBox extends SingleChildRenderObjectWidget {
  const _RetainedTransformBox({
    required this.retainedSize,
    required this.visualRect,
    required this.globalClipRect,
    required super.child,
  });

  final Size retainedSize;
  final Rect visualRect;
  final Rect? globalClipRect;

  @override
  _RenderRetainedTransformBox createRenderObject(BuildContext context) =>
      _RenderRetainedTransformBox(
        retainedSize: retainedSize,
        visualRect: visualRect,
        globalClipRect: globalClipRect,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRetainedTransformBox renderObject,
  ) {
    renderObject
      ..retainedSize = retainedSize
      ..visualRect = visualRect
      ..globalClipRect = globalClipRect;
  }
}

class _RenderRetainedTransformBox extends RenderProxyBox {
  _RenderRetainedTransformBox({
    required Size retainedSize,
    required Rect visualRect,
    required Rect? globalClipRect,
  }) : _retainedSize = retainedSize,
       _visualRect = visualRect,
       _globalClipRect = globalClipRect;

  Size _retainedSize;

  set retainedSize(Size value) {
    if (_retainedSize == value) {
      return;
    }
    _retainedSize = value;
    markNeedsLayout();
  }

  Rect _visualRect;

  set visualRect(Rect value) {
    if (_visualRect == value) {
      return;
    }
    _visualRect = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Rect? _globalClipRect;

  set globalClipRect(Rect? value) {
    if (_globalClipRect == value) {
      return;
    }
    _globalClipRect = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Matrix4 get _visualTransform {
    final scaleX = _retainedSize.width > 0
        ? _visualRect.width / _retainedSize.width
        : 1.0;
    final scaleY = _retainedSize.height > 0
        ? _visualRect.height / _retainedSize.height
        : 1.0;
    return Matrix4.diagonal3Values(scaleX, scaleY, 1)
      ..setTranslationRaw(_visualRect.left, _visualRect.top, 0);
  }

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth && constraints.hasBoundedHeight);
    size = constraints.biggest;
    child?.layout(BoxConstraints.tight(_retainedSize), parentUsesSize: true);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final clip = _globalClipRect;
    if (clip != null && !clip.contains(position)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) {
      return false;
    }
    return result.addWithPaintTransform(
      transform: _visualTransform,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      return;
    }

    void paintTransformed(PaintingContext context, Offset offset) {
      context.pushTransform(
        needsCompositing,
        offset,
        _visualTransform,
        (context, offset) => super.paint(context, offset),
      );
    }

    final clip = _globalClipRect;
    if (clip == null) {
      paintTransformed(context, offset);
      return;
    }
    context.pushClipRect(
      needsCompositing,
      offset,
      clip,
      paintTransformed,
      clipBehavior: Clip.hardEdge,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_visualTransform);
  }
}
