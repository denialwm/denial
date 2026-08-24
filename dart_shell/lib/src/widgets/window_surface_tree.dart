import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';

const double _nativePixelTolerance = 1.0;
const double _coverageTolerance = 0.001;

bool _sourceMatchesOutputPixels({
  required Size targetSize,
  required Rect sourceRect,
  required double devicePixelRatio,
}) {
  final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0.0
      ? devicePixelRatio
      : 1.0;
  final sourceOriginIsIntegral =
      (sourceRect.left - sourceRect.left.roundToDouble()).abs() < 0.001 &&
      (sourceRect.top - sourceRect.top.roundToDouble()).abs() < 0.001;
  return sourceOriginIsIntegral &&
      sourceRect.width + _coverageTolerance >= targetSize.width * ratio &&
      sourceRect.height + _coverageTolerance >= targetSize.height * ratio &&
      sourceRect.width - targetSize.width * ratio <= _nativePixelTolerance &&
      sourceRect.height - targetSize.height * ratio <= _nativePixelTolerance;
}

FilterQuality _effectiveTextureFilterQuality({
  required FilterQuality requested,
  required int transform,
  required Size targetSize,
  required Rect sourceRect,
  required double devicePixelRatio,
}) {
  if (requested != FilterQuality.none) {
    return requested;
  }
  final nativePixels =
      transform == 0 &&
      _sourceMatchesOutputPixels(
        targetSize: targetSize,
        sourceRect: sourceRect,
        devicePixelRatio: devicePixelRatio,
      );
  // FilterQuality.low is Flutter's bilinear sampler. Preserve nearest
  // sampling only when every client pixel already maps to one output pixel.
  return nativePixels ? FilterQuality.none : FilterQuality.low;
}

/// Composites the non-popup portion of a Wayland surface tree in protocol
/// order. Popup layers are scene-level siblings because they are allowed to
/// extend beyond the owning window's clipped frame.
class WindowSurfaceTree extends StatelessWidget {
  const WindowSurfaceTree({
    super.key,
    required this.window,
    this.filterQuality = FilterQuality.none,
    this.includePopups = false,
  });

  final DenialWindow window;
  final FilterQuality filterQuality;
  final bool includePopups;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final target = constraints.biggest;
        if (target.isEmpty) {
          return const SizedBox.shrink();
        }

        if (window.surfaceLayers.isEmpty) {
          return _LegacyWindowTexture(
            window: window,
            filterQuality: filterQuality,
          );
        }

        final targetRect = Offset.zero & target;
        return ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final layer
                  in includePopups
                      ? window.surfaceLayers
                      : window.mainSurfaceLayers)
                if (layer.textureId > 0)
                  Positioned.fromRect(
                    rect: window.mapSurfaceRect(layer, targetRect),
                    child: SurfaceLayerTexture(
                      layer: layer,
                      filterQuality: filterQuality,
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class SurfaceLayerTexture extends StatelessWidget {
  const SurfaceLayerTexture({
    super.key,
    required this.layer,
    this.filterQuality = FilterQuality.none,
  });

  final DenialSurfaceLayer layer;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final target = constraints.biggest;
        final bufferWidth = layer.width.toDouble();
        final bufferHeight = layer.height.toDouble();
        final sourceWidth = layer.textureSourceWidth;
        final sourceHeight = layer.textureSourceHeight;
        if (layer.textureId <= 0 ||
            target.isEmpty ||
            bufferWidth <= 0.0 ||
            bufferHeight <= 0.0 ||
            sourceWidth <= 0.0 ||
            sourceHeight <= 0.0) {
          return const SizedBox.shrink();
        }
        final sourceRect = Rect.fromLTWH(
          layer.textureSourceX,
          layer.textureSourceY,
          sourceWidth,
          sourceHeight,
        );
        final effectiveFilterQuality = _effectiveTextureFilterQuality(
          requested: filterQuality,
          transform: layer.transform,
          targetSize: target,
          sourceRect: sourceRect,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return _SurfaceOpacity(
          opacity: layer.opacity,
          child: _ExternalTextureViewport(
            bufferSize: Size(bufferWidth, bufferHeight),
            sourceRect: sourceRect,
            alignNativePixels:
                effectiveFilterQuality == FilterQuality.none &&
                layer.transform == 0,
            child: RepaintBoundary(
              child: Texture(
                textureId: layer.textureId,
                filterQuality: effectiveFilterQuality,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LegacyWindowTexture extends StatelessWidget {
  const _LegacyWindowTexture({
    required this.window,
    required this.filterQuality,
  });

  final DenialWindow window;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final target = constraints.biggest;
        final bufferWidth = window.width.toDouble();
        final bufferHeight = window.height.toDouble();
        final sourceWidth = window.textureSourceWidth;
        final sourceHeight = window.textureSourceHeight;
        if (window.textureId <= 0 ||
            target.isEmpty ||
            bufferWidth <= 0.0 ||
            bufferHeight <= 0.0 ||
            sourceWidth <= 0.0 ||
            sourceHeight <= 0.0) {
          return const SizedBox.shrink();
        }
        final sourceRect = Rect.fromLTWH(
          window.textureSourceX,
          window.textureSourceY,
          sourceWidth,
          sourceHeight,
        );
        final effectiveFilterQuality = _effectiveTextureFilterQuality(
          requested: filterQuality,
          transform: window.transform,
          targetSize: target,
          sourceRect: sourceRect,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return _SurfaceOpacity(
          opacity: window.opacity,
          child: _ExternalTextureViewport(
            bufferSize: Size(bufferWidth, bufferHeight),
            sourceRect: sourceRect,
            alignNativePixels:
                effectiveFilterQuality == FilterQuality.none &&
                window.transform == 0,
            child: RepaintBoundary(
              child: Texture(
                textureId: window.textureId,
                filterQuality: effectiveFilterQuality,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Keeps an already-rasterized client buffer on the Flutter atlas pixel grid.
///
/// Fractional-scale clients round their buffer dimensions to whole pixels. A
/// logical surface can therefore be 801 logical pixels wide while its 1.5x
/// buffer is 1202 pixels wide. Stretching that image back into exactly 801
/// logical pixels makes Flutter sample 1202 source pixels into 1201.5 atlas
/// pixels. A half-pixel surface origin introduces the same problem even when
/// the dimensions divide exactly.
///
/// When the source covers the atlas-sized destination with at most one pixel
/// of rounding excess, retain its native pixel dimensions instead of
/// resampling it. Its origin is aligned too when that cannot expose an edge.
/// The surrounding surface clip absorbs only the fractional edge remainder.
/// Real resizes, animations, legacy integer-scale buffers, and transformed
/// surfaces continue through Flutter's normal filtered scaling path.
class _ExternalTextureViewport extends SingleChildRenderObjectWidget {
  const _ExternalTextureViewport({
    required this.bufferSize,
    required this.sourceRect,
    required this.alignNativePixels,
    required super.child,
  });

  final Size bufferSize;
  final Rect sourceRect;
  final bool alignNativePixels;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderExternalTextureViewport(
      bufferSize: bufferSize,
      sourceRect: sourceRect,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      alignNativePixels: alignNativePixels,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderExternalTextureViewport renderObject,
  ) {
    renderObject
      ..bufferSize = bufferSize
      ..sourceRect = sourceRect
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..alignNativePixels = alignNativePixels;
  }
}

class _RenderExternalTextureViewport extends RenderShiftedBox {
  _RenderExternalTextureViewport({
    required this._bufferSize,
    required this._sourceRect,
    required this._devicePixelRatio,
    required this._alignNativePixels,
    RenderBox? child,
  }) : super(child);

  Size _bufferSize;
  Rect _sourceRect;
  double _devicePixelRatio;
  bool _alignNativePixels;
  bool _usesNativePixels = false;
  Offset _paintOffset = Offset.zero;

  Size get bufferSize => _bufferSize;

  set bufferSize(Size value) {
    if (_bufferSize == value) {
      return;
    }
    _bufferSize = value;
    markNeedsLayout();
  }

  Rect get sourceRect => _sourceRect;

  set sourceRect(Rect value) {
    if (_sourceRect == value) {
      return;
    }
    _sourceRect = value;
    markNeedsLayout();
  }

  double get devicePixelRatio => _devicePixelRatio;

  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsLayout();
  }

  bool get alignNativePixels => _alignNativePixels;

  set alignNativePixels(bool value) {
    if (_alignNativePixels == value) {
      return;
    }
    _alignNativePixels = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) {
      return;
    }

    final ratio = _devicePixelRatio.isFinite && _devicePixelRatio > 0.0
        ? _devicePixelRatio
        : 1.0;
    _usesNativePixels =
        _alignNativePixels &&
        _sourceMatchesOutputPixels(
          targetSize: size,
          sourceRect: _sourceRect,
          devicePixelRatio: ratio,
        );

    final scaleX = _usesNativePixels
        ? 1.0 / ratio
        : size.width / _sourceRect.width;
    final scaleY = _usesNativePixels
        ? 1.0 / ratio
        : size.height / _sourceRect.height;
    child.layout(
      BoxConstraints.tight(
        Size(_bufferSize.width * scaleX, _bufferSize.height * scaleY),
      ),
      parentUsesSize: true,
    );
    final childParentData = child.parentData! as BoxParentData;
    childParentData.offset = Offset(
      -_sourceRect.left * scaleX,
      -_sourceRect.top * scaleY,
    );
    _paintOffset = childParentData.offset;
  }

  Offset _physicalPixelCorrection() {
    if (!_usesNativePixels) {
      return Offset.zero;
    }
    final transform = getTransformTo(null);
    final translation = MatrixUtils.getAsTranslation(transform);
    if (translation == null) {
      return Offset.zero;
    }
    final ratio = _devicePixelRatio.isFinite && _devicePixelRatio > 0.0
        ? _devicePixelRatio
        : 1.0;
    return Offset(
      _safeAxisCorrection(
        logicalOrigin: translation.dx,
        logicalExtent: size.width,
        sourceExtent: _sourceRect.width,
        ratio: ratio,
      ),
      _safeAxisCorrection(
        logicalOrigin: translation.dy,
        logicalExtent: size.height,
        sourceExtent: _sourceRect.height,
        ratio: ratio,
      ),
    );
  }

  double _safeAxisCorrection({
    required double logicalOrigin,
    required double logicalExtent,
    required double sourceExtent,
    required double ratio,
  }) {
    // getTransformTo(null) deliberately stops at the RenderView and therefore
    // reports the global position in logical pixels. Apply the view DPR once
    // here to reason about actual atlas pixel coverage.
    final physicalOrigin = logicalOrigin * ratio;
    final physicalEnd = physicalOrigin + logicalExtent * ratio;
    final lower = physicalOrigin.floorToDouble();
    final upper = physicalOrigin.ceilToDouble();
    final candidates = lower == upper
        ? <double>[lower]
        : <double>[lower, upper];
    double? alignedOrigin;
    for (final candidate in candidates) {
      final coversViewport =
          candidate <= physicalOrigin + _coverageTolerance &&
          candidate + sourceExtent >= physicalEnd - _coverageTolerance;
      if (coversViewport &&
          (alignedOrigin == null ||
              (candidate - physicalOrigin).abs() <
                  (alignedOrigin - physicalOrigin).abs())) {
        alignedOrigin = candidate;
      }
    }
    return alignedOrigin == null ? 0.0 : alignedOrigin / ratio - logicalOrigin;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      return;
    }
    final childParentData = child.parentData! as BoxParentData;
    _paintOffset = childParentData.offset + _physicalPixelCorrection();
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset + _paintOffset),
      clipBehavior: Clip.hardEdge,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: _paintOffset,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    assert(child == this.child);
    transform.translateByDouble(_paintOffset.dx, _paintOffset.dy, 0.0, 1.0);
  }
}

class _SurfaceOpacity extends StatelessWidget {
  const _SurfaceOpacity({required this.opacity, required this.child});

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final effectiveOpacity = opacity.clamp(0.0, 1.0).toDouble();
    return effectiveOpacity >= 1.0
        ? child
        : Opacity(opacity: effectiveOpacity, child: child);
  }
}
