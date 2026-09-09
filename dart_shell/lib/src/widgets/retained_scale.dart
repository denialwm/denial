import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Scales a retained child around its center without building on each tick.
/// The render transform also supplies the matching hit-test and semantics map.
class RetainedScale extends SingleChildRenderObjectWidget {
  const RetainedScale({super.key, required this.scale, super.child});

  final ValueListenable<double> scale;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRetainedScale(scale);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderRetainedScale).scaleListenable = scale;
  }
}

class _RenderRetainedScale extends RenderTransform {
  _RenderRetainedScale(this._scale)
    : super(transform: Matrix4.identity(), alignment: Alignment.center);

  ValueListenable<double> _scale;
  double? _applied;

  set scaleListenable(ValueListenable<double> value) {
    if (identical(_scale, value)) return;
    if (attached) _scale.removeListener(_changed);
    _scale = value;
    if (attached) _scale.addListener(_changed);
    _changed();
  }

  void _changed() {
    final value = _scale.value;
    if (_applied == value) return;
    _applied = value;
    transform = Matrix4.diagonal3Values(value, value, 1);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scale.addListener(_changed);
    _changed();
  }

  @override
  void detach() {
    _scale.removeListener(_changed);
    super.detach();
  }
}
