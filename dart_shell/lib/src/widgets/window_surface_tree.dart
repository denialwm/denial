import 'package:flutter/widgets.dart';

import '../models/hypr_window.dart';

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

  final HyprWindow window;
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
              for (final layer in includePopups
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

  final HyprSurfaceLayer layer;
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

        final usesWholeBuffer = layer.textureSourceX.abs() < 0.001 &&
            layer.textureSourceY.abs() < 0.001 &&
            (sourceWidth - bufferWidth).abs() < 0.001 &&
            (sourceHeight - bufferHeight).abs() < 0.001;
        if (usesWholeBuffer) {
          return _SurfaceOpacity(
            opacity: layer.opacity,
            child: RepaintBoundary(
              child: Texture(
                textureId: layer.textureId,
                filterQuality: filterQuality,
              ),
            ),
          );
        }

        final scaleX = target.width / sourceWidth;
        final scaleY = target.height / sourceHeight;
        return _SurfaceOpacity(
          opacity: layer.opacity,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: -layer.textureSourceX * scaleX,
                  top: -layer.textureSourceY * scaleY,
                  width: bufferWidth * scaleX,
                  height: bufferHeight * scaleY,
                  child: RepaintBoundary(
                    child: Texture(
                      textureId: layer.textureId,
                      filterQuality: filterQuality,
                    ),
                  ),
                ),
              ],
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

  final HyprWindow window;
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

        final usesWholeBuffer = window.textureSourceX.abs() < 0.001 &&
            window.textureSourceY.abs() < 0.001 &&
            (sourceWidth - bufferWidth).abs() < 0.001 &&
            (sourceHeight - bufferHeight).abs() < 0.001;
        if (usesWholeBuffer) {
          return _SurfaceOpacity(
            opacity: window.opacity,
            child: RepaintBoundary(
              child: Texture(
                textureId: window.textureId,
                filterQuality: filterQuality,
              ),
            ),
          );
        }

        final scaleX = target.width / sourceWidth;
        final scaleY = target.height / sourceHeight;
        return _SurfaceOpacity(
          opacity: window.opacity,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: -window.textureSourceX * scaleX,
                  top: -window.textureSourceY * scaleY,
                  width: bufferWidth * scaleX,
                  height: bufferHeight * scaleY,
                  child: RepaintBoundary(
                    child: Texture(
                      textureId: window.textureId,
                      filterQuality: filterQuality,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SurfaceOpacity extends StatelessWidget {
  const _SurfaceOpacity({
    required this.opacity,
    required this.child,
  });

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
