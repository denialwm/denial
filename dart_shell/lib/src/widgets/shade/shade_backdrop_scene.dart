import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../theme/shell_theme.dart';
import '../../theme/glass_configuration.dart';

/// One screen-coordinate blur input for the shade. Glass keeps its per-surface
/// geometry; ordinary blur does not need moving, individually filtered layers.
class ShadeBackdropScene extends SingleChildRenderObjectWidget {
  const ShadeBackdropScene({
    required this.progress,
    required super.child,
    super.key,
  });
  final Animation<double> progress;

  static bool sharesBlur(BuildContext context) =>
      context.findAncestorRenderObjectOfType<RenderShadeBackdropScene>() !=
          null &&
      ShellTheme.of(context).transparencyMode == ShellTransparencyMode.blur;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderShadeBackdropScene(progress, ShellTheme.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderShadeBackdropScene renderObject,
  ) {
    renderObject.update(progress, ShellTheme.of(context));
  }
}

class RenderShadeBackdropScene extends RenderProxyBox {
  RenderShadeBackdropScene(this._progress, this._theme);
  Animation<double> _progress;
  ShellThemeData _theme;
  final _regions = <_RenderShadeBackdropRegion>{};
  final _clip = LayerHandle<ClipPathLayer>();
  final _filter = LayerHandle<BackdropFilterLayer>();

  void update(Animation<double> progress, ShellThemeData theme) {
    if (_progress != progress) {
      if (attached) _progress.removeListener(markNeedsPaint);
      _progress = progress;
      if (attached) _progress.addListener(markNeedsPaint);
    }
    _theme = theme;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  Iterable<Path> occludersFor(RenderObject target) sync* {
    for (final region in _regions) {
      if (region.occludesNotifications && region.hasSize) {
        yield region.shapeIn(target);
      }
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_progress.value <= 0) return;
    // Dim the scene before taking its shared backdrop sample. The panel and
    // cards stay bright, and the shade follows interactive motion directly.
    context.canvas.drawRect(
      offset & size,
      Paint()
        ..color = Color.fromRGBO(
          0,
          0,
          0,
          0.2 * _progress.value.clamp(0.0, 1.0),
        ),
    );
    if (_theme.transparencyMode == ShellTransparencyMode.blur &&
        _theme.backdropBlurSigma > 0 &&
        _theme.effectivePanelOpacity < 1) {
      final coverage = Path();
      for (final region in _regions) {
        if (region.participates && region.hasSize && !region.size.isEmpty) {
          // Same winding gives a union without per-frame boolean path ops.
          coverage.addPath(region.shapeIn(this), Offset.zero);
        }
      }
      if (!coverage.getBounds().isEmpty) {
        final filter = _filter.layer ??= BackdropFilterLayer();
        filter
          ..filter = _theme
              .backdropFilterConfigAt(1)
              .resolve(ImageFilterContext(bounds: offset & size))
          ..blendMode = BlendMode.src;
        _clip.layer = context.pushClipPath(
          true,
          offset,
          Offset.zero & size,
          coverage,
          (context, offset) => context.pushLayer(filter, (_, _) {}, offset),
          oldLayer: _clip.layer,
        );
      }
    }
    super.paint(context, offset);
  }

  @override
  void dispose() {
    _clip.layer = null;
    _filter.layer = null;
    super.dispose();
  }
}

class ShadeBackdropRegion extends SingleChildRenderObjectWidget {
  const ShadeBackdropRegion({
    required this.borderRadius,
    required super.child,
    this.occludesNotifications = false,
    super.key,
  });
  final BorderRadius borderRadius;
  final bool occludesNotifications;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderShadeBackdropRegion(borderRadius, occludesNotifications);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderShadeBackdropRegion).update(
      borderRadius,
      occludesNotifications,
    );
  }
}

class _RenderShadeBackdropRegion extends RenderProxyBox {
  _RenderShadeBackdropRegion(this.radius, this.occludesNotifications);
  BorderRadius radius;
  bool occludesNotifications;
  RenderShadeBackdropScene? _scene;
  Path? _shape;
  RenderSliverMultiBoxAdaptor? _sliver;
  RenderBox? _row;
  bool get participates =>
      _sliver == null || (_row != null && _sliver!.paintsChild(_row!));

  Path shapeIn(RenderObject target) =>
      (_shape ??= Path()..addRRect(radius.toRRect(Offset.zero & size)))
          .transform(getTransformTo(target).storage);

  void update(BorderRadius value, bool occludes) {
    radius = value;
    occludesNotifications = occludes;
    _shape = null;
    _scene?.markNeedsPaint();
  }

  @override
  void performLayout() {
    super.performLayout();
    _shape = null;
    _scene?.markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    RenderObject below = this;
    while (ancestor != null && ancestor is! RenderShadeBackdropScene) {
      if (ancestor is RenderSliverMultiBoxAdaptor && below is RenderBox) {
        _sliver = ancestor;
        _row = below;
      }
      below = ancestor;
      ancestor = ancestor.parent;
    }
    _scene = ancestor as RenderShadeBackdropScene?;
    _scene?._regions.add(this);
    _scene?.markNeedsPaint();
  }

  @override
  void detach() {
    final scene = _scene;
    scene?._regions.remove(this);
    if (scene?.attached ?? false) scene!.markNeedsPaint();
    _scene = null;
    super.detach();
  }
}
