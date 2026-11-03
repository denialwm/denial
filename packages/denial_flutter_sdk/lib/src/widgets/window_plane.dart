import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// An imported client image and its Wayland viewport, before window effects.
@immutable
class WindowPlaneTexture {
  const WindowPlaneTexture({
    required this.id,
    required this.bufferSize,
    required this.source,
    this.destination = const Rect.fromLTWH(0, 0, 1, 1),
    this.transform = 0,
    this.opacity = 1,
  });

  final int id;
  final Size bufferSize;
  final Rect source;

  /// Destination as fractions of the client area (may extend beyond it).
  final Rect destination;
  final int transform;
  final double opacity;

  bool get isValid =>
      id > 0 &&
      !bufferSize.isEmpty &&
      source.isFinite &&
      !source.isEmpty &&
      destination.isFinite &&
      !destination.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is WindowPlaneTexture &&
      other.id == id &&
      other.bufferSize == bufferSize &&
      other.source == source &&
      other.destination == destination &&
      other.transform == transform &&
      other.opacity == opacity;

  @override
  int get hashCode =>
      Object.hash(id, bufferSize, source, destination, transform, opacity);
}

/// Denial's window rendering primitive.
///
/// The imported-texture constructor issues one window draw: client, cached
/// glass/blur, transparency, analytic rounded edges and colored frame. The
/// child constructor first composes its child (for subsurfaces or Flutter
/// applications), then uses exactly the same final window shader. Neither
/// contract relies on the engine recognizing a widget/clip/paint pattern.
/// Shadows are deliberately independent cached decorations.
class WindowPlane extends SingleChildRenderObjectWidget {
  const WindowPlane.texture({
    super.key,
    required WindowPlaneTexture this.texture,
    this.radius = 0,
    this.frameWidth = 0,
    this.frameColor = const Color(0x00000000),
    this.backdrop,
    this.materialRegion,
    this.filterQuality = FilterQuality.none,
    this.presentationScale = 1,
    this.pixelGridOrigin = Offset.zero,
  });

  const WindowPlane.child({
    super.key,
    required super.child,
    this.radius = 0,
    this.frameWidth = 0,
    this.frameColor = const Color(0x00000000),
    this.backdrop,
  }) : texture = null,
       materialRegion = null,
       filterQuality = FilterQuality.none,
       presentationScale = 1,
       pixelGridOrigin = Offset.zero;

  final WindowPlaneTexture? texture;
  final double radius;
  final double frameWidth;
  final Color frameColor;
  final ImageFilterConfig? backdrop;

  /// The part of the client area that receives [backdrop], in fractions of
  /// its size, such as a popup's window geometry inside its client-drawn
  /// shadow. The material takes its shape from it and is only evaluated there.
  final Rect? materialRegion;
  final FilterQuality filterQuality;
  final double presentationScale;
  final Offset pixelGridOrigin;

  @override
  RenderWindowPlane createRenderObject(BuildContext context) =>
      RenderWindowPlane(this);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderWindowPlane renderObject,
  ) {
    renderObject.configuration = this;
  }
}

class RenderWindowPlane extends RenderShiftedBox {
  RenderWindowPlane(this._configuration) : super(null);

  WindowPlane _configuration;
  set configuration(WindowPlane value) {
    final previous = _configuration;
    _configuration = value;
    if (value.frameWidth != previous.frameWidth) {
      markNeedsLayout();
    } else if (value.texture != previous.texture ||
        value.radius != previous.radius ||
        value.frameColor != previous.frameColor ||
        value.backdrop != previous.backdrop ||
        value.materialRegion != previous.materialRegion ||
        value.filterQuality != previous.filterQuality ||
        value.presentationScale != previous.presentationScale ||
        value.pixelGridOrigin != previous.pixelGridOrigin) {
      // A rebuild with the same window, as when its card's list rebuilds,
      // keeps the painted plane.
      markNeedsPaint();
    }
  }

  final LayerHandle<_WindowPlaneLayer> _windowLayer = LayerHandle();

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  Rect get paintBounds => (Offset.zero & size).inflate(1);

  Rect get _content => (Offset.zero & size).deflate(
    _configuration.frameWidth.clamp(0, size.shortestSide / 2),
  );

  @override
  void performLayout() {
    size = constraints.biggest;
    final content = _content;
    child?.layout(BoxConstraints.tight(content.size), parentUsesSize: true);
    if (child != null) {
      (child!.parentData! as BoxParentData).offset = content.topLeft;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!_content.contains(position)) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final config = _configuration;
    final content = _content.shift(offset);
    final layer = _windowLayer.layer ??= _WindowPlaneLayer();
    final region = config.materialRegion;
    final material = region == null
        ? null
        : Rect.fromLTRB(
            content.left + region.left * content.width,
            content.top + region.top * content.height,
            content.left + region.right * content.width,
            content.top + region.bottom * content.height,
          );
    layer
      ..bounds = offset & size
      ..content = content
      ..material = material
      ..radius = config.radius
      ..frameColor = config.frameColor
      ..backdrop = config.backdrop?.resolve(
        ImageFilterContext(bounds: material ?? content),
      )
      ..texture = config.texture;
    final texture = config.texture;
    if (texture != null) {
      final target = Rect.fromLTWH(
        content.left + texture.destination.left * content.width,
        content.top + texture.destination.top * content.height,
        texture.destination.width * content.width,
        texture.destination.height * content.height,
      );
      final geometry = windowPlaneTextureGeometry(
        texture: texture,
        target: target,
        requested: config.filterQuality,
        presentationScale: config.presentationScale,
        // RenderView-relative coordinates are logical, just like the existing
        // external texture viewport. Align only when the buffer still covers
        // the entire fractional viewport after the correction.
        globalOrigin: MatrixUtils.getAsTranslation(getTransformTo(null)),
        localTargetOrigin: target.topLeft - offset,
        pixelGridOrigin: config.pixelGridOrigin,
      );
      layer
        ..textureBounds = geometry.bounds
        ..textureTransform = geometry.transform
        ..filterQuality = geometry.filterQuality;
    }
    layer.invalidateScene();
    context.pushLayer(layer, super.paint, offset);
  }

  @override
  void dispose() {
    _windowLayer.layer = null;
    super.dispose();
  }
}

typedef WindowPlaneTextureGeometry = ({
  Rect bounds,
  Matrix4 transform,
  FilterQuality filterQuality,
});

/// Pure geometry shared by the primitive's layout and headless tests.
WindowPlaneTextureGeometry windowPlaneTextureGeometry({
  required WindowPlaneTexture texture,
  required Rect target,
  required FilterQuality requested,
  required double presentationScale,
  Offset? globalOrigin,
  Offset localTargetOrigin = Offset.zero,
  Offset pixelGridOrigin = Offset.zero,
}) {
  if (!texture.isValid || target.isEmpty) {
    return (
      bounds: Rect.zero,
      transform: Matrix4.identity(),
      filterQuality: requested,
    );
  }
  final source = texture.source;
  final ratio = presentationScale.isFinite && presentationScale > 0
      ? presentationScale
      : 1.0;
  final integralSource =
      (source.left - source.left.roundToDouble()).abs() < 0.001 &&
      (source.top - source.top.roundToDouble()).abs() < 0.001;
  final nativePixels =
      texture.transform == 0 &&
      integralSource &&
      source.width + 0.001 >= target.width * ratio &&
      source.height + 0.001 >= target.height * ratio &&
      source.width - target.width * ratio <= 1 &&
      source.height - target.height * ratio <= 1;
  final quality = requested == FilterQuality.none && !nativePixels
      ? FilterQuality.low
      : requested;
  final native = quality == FilterQuality.none && nativePixels;
  final quarterTurns = texture.transform & 3;
  final rotated = quarterTurns.isOdd;
  final viewport = rotated ? Size(target.height, target.width) : target.size;
  final sx = native ? 1 / ratio : viewport.width / source.width;
  final sy = native ? 1 / ratio : viewport.height / source.height;
  Offset correction = Offset.zero;
  if (native && globalOrigin != null) {
    double align(
      double origin,
      double extent,
      double sourceExtent,
      double grid,
    ) {
      final start = (origin - grid) * ratio;
      final end = start + extent * ratio;
      double? nearest;
      for (final candidate in [start.floorToDouble(), start.ceilToDouble()]) {
        if (candidate <= start + 0.001 &&
            candidate + sourceExtent >= end - 0.001 &&
            (nearest == null ||
                (candidate - start).abs() < (nearest - start).abs())) {
          nearest = candidate;
        }
      }
      return nearest == null ? 0 : nearest / ratio + grid - origin;
    }

    final origin = globalOrigin + localTargetOrigin;
    correction = Offset(
      align(origin.dx, target.width, source.width, pixelGridOrigin.dx),
      align(origin.dy, target.height, source.height, pixelGridOrigin.dy),
    );
  }
  final transform = Matrix4.translationValues(
    target.left + correction.dx,
    target.top + correction.dy,
    0,
  );
  if (texture.transform & 4 != 0) {
    transform
      ..translateByDouble(target.width, 0, 0, 1)
      ..scaleByDouble(-1, 1, 1, 1);
  }
  switch (quarterTurns) {
    case 1:
      transform.translateByDouble(target.width, 0, 0, 1);
    case 2:
      transform.translateByDouble(target.width, target.height, 0, 1);
    case 3:
      transform.translateByDouble(0, target.height, 0, 1);
  }
  if (quarterTurns != 0) transform.rotateZ(quarterTurns * math.pi / 2);
  return (
    bounds: Rect.fromLTWH(
      -source.left * sx,
      -source.top * sy,
      texture.bufferSize.width * sx,
      texture.bufferSize.height * sy,
    ),
    transform: transform,
    filterQuality: quality,
  );
}

class _WindowPlaneLayer extends ContainerLayer {
  Rect bounds = Rect.zero;
  Rect content = Rect.zero;
  Rect? material;
  double radius = 0;
  Color frameColor = const Color(0x00000000);
  ui.ImageFilter? backdrop;
  WindowPlaneTexture? texture;
  Rect textureBounds = Rect.zero;
  Matrix4 textureTransform = Matrix4.identity();
  FilterQuality filterQuality = FilterQuality.none;

  void invalidateScene() => markNeedsAddToScene();

  @override
  void addToScene(ui.SceneBuilder builder) {
    engineLayer = builder.pushWindowSurface(
      bounds,
      contentBounds: content,
      materialBounds: material,
      radius: radius,
      frameColor: frameColor,
      backdrop: backdrop,
      textureId: texture == null
          ? -1
          : texture!.isValid
          ? texture!.id
          : 0,
      textureBounds: textureBounds,
      textureTransform: textureTransform.storage,
      textureOpacity: texture?.opacity.clamp(0.0, 1.0) ?? 1,
      filterQuality: filterQuality,
      oldLayer: engineLayer as ui.WindowSurfaceEngineLayer?,
    );
    if (texture == null) addChildrenToScene(builder);
    builder.pop();
  }
}
