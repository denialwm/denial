import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays [child] out once at [size] and draws it scaled into [rect], in this
/// widget's coordinates, wherever that rectangle moves.
///
/// Moving a laid-out icon this way repaints and relayouts nothing: an icon
/// rasterized for one size would otherwise rasterize again at every size.
class RectFollower extends SingleChildRenderObjectWidget {
  const RectFollower({
    super.key,
    required this.rect,
    required this.size,
    super.child,
  });

  final ValueListenable<Rect> rect;
  final Size size;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRectFollower(rect, size);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderRectFollower)
      ..rect = rect
      ..childSize = size;
  }
}

class _RenderRectFollower extends RenderProxyBox {
  _RenderRectFollower(this._rect, this._childSize);

  ValueListenable<Rect> _rect;
  Size _childSize;
  final _transform = LayerHandle<TransformLayer>();

  set rect(ValueListenable<Rect> value) {
    if (identical(value, _rect)) return;
    if (attached) {
      _rect.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _rect = value;
    markNeedsPaint();
  }

  set childSize(Size value) {
    if (value == _childSize) return;
    _childSize = value;
    markNeedsLayout();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _rect.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _rect.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    child?.layout(BoxConstraints.tight(_childSize));
    size = constraints.biggest;
  }

  Matrix4 get _matrix {
    final rect = _rect.value;
    final scale = _childSize.width <= 0 ? 1.0 : rect.width / _childSize.width;
    return Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(rect.left, rect.top, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    _transform.layer = context.pushTransform(
      needsCompositing,
      offset,
      _matrix,
      (context, offset) => context.paintChild(child!, offset),
      oldLayer: _transform.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_matrix);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  @override
  void dispose() {
    _transform.layer = null;
    super.dispose();
  }
}
