import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Where a [PosedWindow] draws its child: a rectangle in the widget's own
/// coordinates, the radius of its corners, and its opacity.
@immutable
class WindowPose {
  const WindowPose(this.rect, this.radius, {this.opacity = 1});

  static const WindowPose hidden = WindowPose(Rect.zero, 0, opacity: 0);

  final Rect rect;
  final double radius;
  final double opacity;

  @override
  bool operator ==(Object other) =>
      other is WindowPose &&
      other.rect == rect &&
      other.radius == radius &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(rect, radius, opacity);
}

/// Draws a full-size child into whatever [pose] currently says.
///
/// The child keeps its layout; a pose change moves one clip and one
/// transform layer and repaints nothing, so a spring can drive [pose] every
/// frame. With [cover] the child scales uniformly to cover the rectangle and
/// overflow is clipped, the way a window fits into a square icon. Below full
/// opacity one more layer fades the posed child; keep that to small poses,
/// since its bounds change every frame.
class PosedWindow extends SingleChildRenderObjectWidget {
  const PosedWindow({
    super.key,
    required this.pose,
    this.cover = true,
    super.child,
  });

  final ValueListenable<WindowPose> pose;
  final bool cover;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPosedWindow(pose, cover);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPosedWindow)
      ..pose = pose
      ..cover = cover;
  }
}

class _RenderPosedWindow extends RenderProxyBox {
  _RenderPosedWindow(this._pose, this._cover);

  ValueListenable<WindowPose> _pose;
  bool _cover;
  final _clip = LayerHandle<ClipRRectLayer>();
  final _transform = LayerHandle<TransformLayer>();
  final _opacity = LayerHandle<OpacityLayer>();

  set pose(ValueListenable<WindowPose> value) {
    if (identical(value, _pose)) return;
    if (attached) {
      _pose.removeListener(_changed);
      value.addListener(_changed);
    }
    _pose = value;
    _changed();
  }

  set cover(bool value) {
    if (value == _cover) return;
    _cover = value;
    _changed();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pose.addListener(_changed);
  }

  @override
  void detach() {
    _pose.removeListener(_changed);
    super.detach();
  }

  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Matrix4 _matrixFor(Rect rect) {
    if (size.isEmpty) return Matrix4.identity();
    var scaleX = rect.width / size.width;
    var scaleY = rect.height / size.height;
    var left = rect.left;
    var top = rect.top;
    if (_cover) {
      scaleX = scaleY = scaleX > scaleY ? scaleX : scaleY;
      left = rect.center.dx - size.width * scaleX / 2;
      top = rect.center.dy - size.height * scaleY / 2;
    }
    return Matrix4.diagonal3Values(scaleX, scaleY, 1)
      ..setTranslationRaw(left, top, 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final pose = _pose.value;
    final alpha = (pose.opacity.clamp(0.0, 1.0) * 255).round();
    if (child == null || size.isEmpty || pose.rect.isEmpty || alpha == 0) {
      _clip.layer = null;
      _transform.layer = null;
      _opacity.layer = null;
      return;
    }
    if (alpha == 255) {
      _opacity.layer = null;
      _paintPosed(context, offset, pose);
      return;
    }
    _opacity.layer = context.pushOpacity(
      offset,
      alpha,
      (context, offset) => _paintPosed(context, offset, pose),
      oldLayer: _opacity.layer,
    );
  }

  void _paintPosed(PaintingContext context, Offset offset, WindowPose pose) {
    final rect = pose.rect;
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      rect,
      RRect.fromRectAndRadius(rect, Radius.circular(pose.radius)),
      (context, offset) {
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
      transform.multiply(_matrixFor(_pose.value.rect));

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final pose = _pose.value;
    if (size.isEmpty ||
        pose.opacity <= 0 ||
        !RRect.fromRectAndRadius(
          pose.rect,
          Radius.circular(pose.radius),
        ).contains(position)) {
      return false;
    }
    return result.addWithPaintTransform(
      transform: _matrixFor(pose.rect),
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    _transform.layer = null;
    _opacity.layer = null;
    super.dispose();
  }
}
