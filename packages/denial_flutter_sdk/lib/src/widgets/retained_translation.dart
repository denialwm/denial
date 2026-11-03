import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Moves an already-built subtree directly from a [ValueListenable].
///
/// Translation updates stop at the render-object boundary: they neither
/// rebuild nor lay out [child]. Hit testing and semantics follow the same
/// transform. When [devicePixelRatio] is supplied, the translation is snapped
/// to physical pixels so a retained external texture stays on the atlas grid.
class RetainedTranslation extends SingleChildRenderObjectWidget {
  const RetainedTranslation({
    super.key,
    required this.translation,
    this.enabled = true,
    this.devicePixelRatio,
    super.child,
  });

  final ValueListenable<Offset> translation;
  final bool enabled;
  final double? devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderRetainedTranslation(translation, enabled, devicePixelRatio);
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderRetainedTranslation)
      ..translation = translation
      ..enabled = enabled
      ..devicePixelRatio = devicePixelRatio;
  }
}

class _RenderRetainedTranslation extends RenderTransform {
  _RenderRetainedTranslation(
    this._translation,
    this._enabled,
    this._devicePixelRatio,
  ) : super(transform: Matrix4.identity(), transformHitTests: true);

  ValueListenable<Offset> _translation;
  bool _enabled;
  double? _devicePixelRatio;
  Offset? _appliedTranslation;

  set translation(ValueListenable<Offset> value) {
    if (identical(value, _translation)) {
      return;
    }
    if (attached) {
      _translation.removeListener(_handleTranslationChanged);
    }
    _translation = value;
    if (attached) {
      _translation.addListener(_handleTranslationChanged);
    }
    _applyTranslation();
  }

  set enabled(bool value) {
    if (value == _enabled) {
      return;
    }
    _enabled = value;
    _applyTranslation();
  }

  set devicePixelRatio(double? value) {
    if (value == _devicePixelRatio) {
      return;
    }
    _devicePixelRatio = value;
    _applyTranslation();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _translation.addListener(_handleTranslationChanged);
    _applyTranslation();
  }

  @override
  void detach() {
    _translation.removeListener(_handleTranslationChanged);
    super.detach();
  }

  void _handleTranslationChanged() => _applyTranslation();

  void _applyTranslation() {
    var value = _enabled ? _translation.value : Offset.zero;
    final scale = _devicePixelRatio;
    if (scale != null && scale.isFinite && scale > 0.0) {
      value = Offset(
        (value.dx * scale).roundToDouble() / scale,
        (value.dy * scale).roundToDouble() / scale,
      );
    }
    if (value == _appliedTranslation) {
      return;
    }
    _appliedTranslation = value;
    setIdentity();
    if (value != Offset.zero) {
      translate(value.dx, value.dy);
    }
  }
}

/// Moves an already-painted subtree by updating only its own layer.
///
/// Unlike [RetainedTranslation], a change neither repaints [child] nor
/// re-records the enclosing repaint boundary: the subtree keeps its pictures
/// and the engine receives a new layer offset. Descendants that paint from
/// their global position, such as glass slices, must follow the same motion
/// through their own listenables, as they already must below any repaint
/// boundary. Hit testing and semantics follow the translation.
///
/// Window planes align their texture to the physical pixel grid when they
/// paint. Pass [devicePixelRatio] above them: whole physical pixel steps keep
/// that alignment valid wherever the layer moves without repainting.
class CompositedTranslation extends SingleChildRenderObjectWidget {
  const CompositedTranslation({
    super.key,
    required this.translation,
    this.devicePixelRatio,
    super.child,
  });

  final ValueListenable<Offset> translation;
  final double? devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCompositedTranslation(translation, devicePixelRatio);
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderCompositedTranslation)
      ..translation = translation
      ..devicePixelRatio = devicePixelRatio;
  }
}

class _RenderCompositedTranslation extends RenderProxyBox {
  _RenderCompositedTranslation(this._translation, this._devicePixelRatio);

  ValueListenable<Offset> _translation;
  double? _devicePixelRatio;
  Offset _applied = Offset.zero;

  set devicePixelRatio(double? value) {
    if (value == _devicePixelRatio) {
      return;
    }
    _devicePixelRatio = value;
    _handleTranslationChanged();
  }

  set translation(ValueListenable<Offset> value) {
    if (identical(value, _translation)) {
      return;
    }
    if (attached) {
      _translation.removeListener(_handleTranslationChanged);
    }
    _translation = value;
    if (attached) {
      _translation.addListener(_handleTranslationChanged);
    }
    _handleTranslationChanged();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _translation.addListener(_handleTranslationChanged);
    _handleTranslationChanged();
  }

  @override
  void detach() {
    _translation.removeListener(_handleTranslationChanged);
    super.detach();
  }

  void _handleTranslationChanged() {
    var value = _translation.value;
    final scale = _devicePixelRatio;
    if (scale != null && scale.isFinite && scale > 0.0) {
      value = Offset(
        (value.dx * scale).roundToDouble() / scale,
        (value.dy * scale).roundToDouble() / scale,
      );
    }
    if (value == _applied) {
      return;
    }
    _applied = value;
    markNeedsCompositedLayerUpdate();
  }

  @override
  OffsetLayer updateCompositedLayer({
    required covariant TransformLayer? oldLayer,
  }) {
    return (oldLayer ?? TransformLayer())
      ..transform = Matrix4.translationValues(_applied.dx, _applied.dy, 0);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: _applied,
      position: position,
      hitTest: (result, transformed) =>
          super.hitTestChildren(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_applied.dx, _applied.dy, 0, 1);
    super.applyPaintTransform(child, transform);
  }
}
