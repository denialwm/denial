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
    this.transformChild = true,
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

  /// False reveals the full-size child through the moving clip without
  /// resizing it, for overlays such as a launch icon that keeps its size.
  final bool transformChild;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWindowMotion(
    progress,
    begin,
    beginIsGlobal,
    end,
    beginRadius,
    endRadius,
    curve,
    transformChild,
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
      transformChild,
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
    this.transformChild,
  );

  Animation<double> _progress;
  Rect begin;
  bool beginIsGlobal;
  Rect end;
  double beginRadius;
  double endRadius;
  Curve curve;
  bool transformChild;
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
    bool nextTransformChild,
  ) {
    if (_progress == progress &&
        begin == nextBegin &&
        beginIsGlobal == nextBeginIsGlobal &&
        end == nextEnd &&
        beginRadius == nextBeginRadius &&
        endRadius == nextEndRadius &&
        curve == nextCurve &&
        transformChild == nextTransformChild) {
      return;
    }
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
    transformChild = nextTransformChild;
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
  Rect _rectAt(double t) {
    final localBegin = beginIsGlobal
        ? Rect.fromPoints(
            globalToLocal(begin.topLeft),
            globalToLocal(begin.bottomRight),
          )
        : begin;
    return Rect.lerp(localBegin, end, t)!;
  }

  Matrix4 _matrixFor(Rect rect) {
    if (!transformChild || size.isEmpty) return Matrix4.identity();
    return Matrix4.diagonal3Values(
      rect.width / size.width,
      rect.height / size.height,
      1,
    )..setTranslationRaw(rect.left, rect.top, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) return;
    final t = _t;
    final rect = _rectAt(t);
    final radius = lerpDouble(beginRadius, endRadius, t)!;
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      rect,
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      (context, offset) {
        if (!transformChild) {
          _transform.layer = null;
          context.paintChild(child!, offset);
          return;
        }
        _transform.layer = context.pushTransform(
          needsCompositing,
          offset,
          _matrixFor(rect),
          (context, offset) => context.paintChild(child!, offset),
          oldLayer: _transform.layer,
        );
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_matrixFor(_rectAt(_t)));

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (size.isEmpty) return false;
    final t = _t;
    final rect = _rectAt(t);
    if (!RRect.fromRectAndRadius(
      rect,
      Radius.circular(lerpDouble(beginRadius, endRadius, t)!),
    ).contains(position)) {
      return false;
    }
    return result.addWithPaintTransform(
      transform: _matrixFor(rect),
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
