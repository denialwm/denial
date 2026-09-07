import 'dart:ui' show lerpDouble;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A window keeps its full-size layout while its composited rectangle moves.
/// Animation ticks update only paint; app layout and texture fitting stay fixed.
class RetainedWindowMotion extends SingleChildRenderObjectWidget {
  const RetainedWindowMotion({
    super.key,
    required this.progress,
    required this.begin,
    this.beginIsGlobal = false,
    required this.end,
    this.beginRadius = 0,
    this.endRadius = 0,
    this.curve = Curves.linear,
    super.child,
  });

  final Animation<double> progress;
  final Rect begin;

  /// Resolve a launcher icon's global bounds after ancestor layout completes.
  final bool beginIsGlobal;
  final Rect end;
  final double beginRadius;
  final double endRadius;
  final Curve curve;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWindowMotion(
    progress,
    begin,
    beginIsGlobal,
    end,
    beginRadius,
    endRadius,
    curve,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderWindowMotion).update(
      progress,
      begin,
      beginIsGlobal,
      end,
      beginRadius,
      endRadius,
      curve,
    );
  }
}

class _RenderWindowMotion extends RenderProxyBox {
  _RenderWindowMotion(
    this._progress,
    this.begin,
    this.beginIsGlobal,
    this.end,
    this.beginRadius,
    this.endRadius,
    this.curve,
  );

  Animation<double> _progress;
  Rect begin;
  bool beginIsGlobal;
  Rect end;
  double beginRadius;
  double endRadius;
  Curve curve;
  final LayerHandle<ClipRRectLayer> _clip = LayerHandle<ClipRRectLayer>();
  final LayerHandle<TransformLayer> _transform = LayerHandle<TransformLayer>();

  void update(
    Animation<double> progress,
    Rect nextBegin,
    bool nextBeginIsGlobal,
    Rect nextEnd,
    double nextBeginRadius,
    double nextEndRadius,
    Curve nextCurve,
  ) {
    if (_progress != progress) {
      if (attached) _progress.removeListener(_changed);
      _progress = progress;
      if (attached) _progress.addListener(_changed);
    }
    begin = nextBegin;
    beginIsGlobal = nextBeginIsGlobal;
    end = nextEnd;
    beginRadius = nextBeginRadius;
    endRadius = nextEndRadius;
    curve = nextCurve;
    _changed();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(_changed);
  }

  @override
  void detach() {
    _progress.removeListener(_changed);
    super.detach();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  double get _t => curve.transform(_progress.value.clamp(0.0, 1.0));
  Rect get _rect {
    final localBegin = beginIsGlobal
        ? Rect.fromPoints(
            globalToLocal(begin.topLeft),
            globalToLocal(begin.bottomRight),
          )
        : begin;
    return Rect.lerp(localBegin, end, _t)!;
  }

  Matrix4 get _matrix {
    final rect = _rect;
    return Matrix4.diagonal3Values(
      rect.width / size.width,
      rect.height / size.height,
      1,
    )..setTranslationRaw(rect.left, rect.top, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    final rect = _rect;
    final radius = lerpDouble(beginRadius, endRadius, _t)!;
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      rect,
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      (context, offset) {
        _transform.layer = context.pushTransform(
          needsCompositing,
          offset,
          _matrix,
          (context, offset) => context.paintChild(child!, offset),
          oldLayer: _transform.layer,
        );
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_matrix);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintTransform(
      transform: _matrix,
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    _transform.layer = null;
    super.dispose();
  }
}
