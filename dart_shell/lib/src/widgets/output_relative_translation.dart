import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Translates [child] by a fraction of each active output's logical size.
///
/// The retained engine layer resolves the factor independently while Denial
/// rasters the shared desktop scene into each output. [fallbackSize] keeps
/// hit-testing, semantics, snapshots, and non-Denial test views deterministic.
class OutputRelativeTranslation extends SingleChildRenderObjectWidget {
  OutputRelativeTranslation({
    super.key,
    required this.offsetFactor,
    required this.fallbackSize,
    super.child,
  }) : assert(offsetFactor.dx.isFinite),
       assert(offsetFactor.dy.isFinite),
       assert(fallbackSize.width > 0.0),
       assert(fallbackSize.height > 0.0);

  final Offset offsetFactor;
  final Size fallbackSize;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderOutputRelativeTranslation(offsetFactor, fallbackSize);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderOutputRelativeTranslation renderObject,
  ) {
    renderObject
      ..offsetFactor = offsetFactor
      ..fallbackSize = fallbackSize;
  }
}

/// The retained render object used by [OutputRelativeTranslation].
class RenderOutputRelativeTranslation extends RenderProxyBox {
  RenderOutputRelativeTranslation(this._offsetFactor, this._fallbackSize);

  Offset get offsetFactor => _offsetFactor;
  Offset _offsetFactor;
  set offsetFactor(Offset value) {
    if (value == _offsetFactor) {
      return;
    }
    final didNeedCompositing = alwaysNeedsCompositing;
    _offsetFactor = value;
    if (didNeedCompositing != alwaysNeedsCompositing) {
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Size get fallbackSize => _fallbackSize;
  Size _fallbackSize;
  set fallbackSize(Size value) {
    if (value == _fallbackSize) {
      return;
    }
    _fallbackSize = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Offset get _fallbackOffset => Offset(
    offsetFactor.dx * fallbackSize.width,
    offsetFactor.dy * fallbackSize.height,
  );

  @override
  bool get alwaysNeedsCompositing =>
      child != null && offsetFactor != Offset.zero;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    return hitTestChildren(result, position: position);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: _fallbackOffset,
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    if (offsetFactor == Offset.zero) {
      layer = null;
      super.paint(context, offset);
      return;
    }

    final outputLayer = switch (layer) {
      final OutputRelativeTransformLayer existing => existing,
      _ => OutputRelativeTransformLayer(
        offsetFactor: offsetFactor,
        fallbackSize: fallbackSize,
      ),
    };
    outputLayer
      ..offsetFactor = offsetFactor
      ..fallbackSize = fallbackSize;
    layer = outputLayer;
    context.pushLayer(outputLayer, super.paint, offset);
    assert(() {
      outputLayer.debugCreator = debugCreator;
      return true;
    }());
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _fallbackOffset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}
