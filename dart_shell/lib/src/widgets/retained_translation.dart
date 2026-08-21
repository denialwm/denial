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
