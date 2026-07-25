import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../state/display_layout.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/wallpaper.dart';
import '../wallpaper/widgets/wallpaper_image.dart';

class ShellWallpaper extends ConsumerWidget {
  const ShellWallpaper({super.key});

  static const String assetPath = defaultShellWallpaperAsset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallpaper = ref.watch(
      wallpaperControllerProvider.select(
        (state) => (
          assignment: state.assignment,
          outgoingAssignment: state.outgoingAssignment,
          transitionTarget: state.transitionTarget,
          revealOriginFraction: state.revealOriginFraction,
          transitionId: state.transitionId,
        ),
      ),
    );
    final displayLayout = ref.watch(displayLayoutProvider);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvas = Offset.zero & constraints.biggest;
        final outputs = _visibleOutputs(displayLayout, canvas);
        final spanRect = _spanRect(outputs, canvas);
        final transitionRect = _transitionRect(
          wallpaper.transitionTarget,
          outputs,
          spanRect,
        );
        final outgoing = wallpaper.outgoingAssignment;
        final animateOutgoing =
            outgoing != null && !reduceMotion && !transitionRect.isEmpty;
        if (outgoing != null && !animateOutgoing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _completeTransition(ref, wallpaper.transitionId);
          });
        }

        return RepaintBoundary(
          child: ColoredBox(
            color: ShellColors.launchSurface,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _WallpaperScene(
                  assignment: wallpaper.assignment,
                  outputs: outputs,
                  spanRect: spanRect,
                ),
                if (animateOutgoing)
                  TweenAnimationBuilder<double>(
                    key: ValueKey<int>(wallpaper.transitionId),
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    duration: Motion.wallpaperReveal,
                    curve: Motion.md3Emphasized,
                    onEnd: () =>
                        _completeTransition(ref, wallpaper.transitionId),
                    builder: (context, progress, child) {
                      return ClipPath(
                        clipper: _ExpandingWallpaperHoleClipper(
                          targetRect: transitionRect,
                          originFraction: wallpaper.revealOriginFraction,
                          progress: progress,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Transform.scale(
                          scale: 1.0 + 0.035 * progress,
                          child: child,
                        ),
                      );
                    },
                    child: _WallpaperScene(
                      assignment: outgoing,
                      outputs: outputs,
                      spanRect: spanRect,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<DisplayOutput> _visibleOutputs(DisplayLayout? layout, Rect canvas) {
    if (layout == null || canvas.isEmpty) {
      return const <DisplayOutput>[];
    }
    return layout.outputs
        .where((output) => !output.logicalRect.intersect(canvas).isEmpty)
        .toList(growable: false);
  }

  Rect _spanRect(List<DisplayOutput> outputs, Rect canvas) {
    if (outputs.isEmpty) {
      return canvas;
    }
    var result = outputs.first.logicalRect.intersect(canvas);
    for (final output in outputs.skip(1)) {
      result = result.expandToInclude(output.logicalRect.intersect(canvas));
    }
    return result;
  }

  Rect _transitionRect(
    WallpaperTarget target,
    List<DisplayOutput> outputs,
    Rect spanRect,
  ) {
    final outputName = target.outputName;
    if (outputName == null) {
      return spanRect;
    }
    for (final output in outputs) {
      if (output.name == outputName) {
        return output.logicalRect;
      }
    }
    return Rect.zero;
  }

  void _completeTransition(WidgetRef ref, int transitionId) {
    ref
        .read(wallpaperControllerProvider.notifier)
        .completeTransition(transitionId);
  }
}

class _WallpaperScene extends StatelessWidget {
  const _WallpaperScene({
    required this.assignment,
    required this.outputs,
    required this.spanRect,
  });

  final WallpaperAssignment assignment;
  final List<DisplayOutput> outputs;
  final Rect spanRect;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fromRect(
          rect: spanRect,
          child: _WallpaperImage(
            resource: assignment.all,
            alignment: Alignment(
              assignment.spanAlignment.x,
              assignment.spanAlignment.y,
            ),
          ),
        ),
        for (final output in outputs)
          if (assignment.outputOverrides[output.name] case final resource?)
            Positioned.fromRect(
              rect: output.logicalRect,
              child: _WallpaperImage(resource: resource),
            ),
        if (outputs.isEmpty && assignment.allDarkness > 0.0)
          Positioned.fromRect(
            rect: spanRect,
            child: _WallpaperDarknessLayer(
              key: const ValueKey<String>('wallpaper-darkness-all'),
              darkness: assignment.allDarkness,
            ),
          ),
        for (final output in outputs)
          if (assignment.darknessForOutput(output.name) > 0.0)
            Positioned.fromRect(
              rect: output.logicalRect,
              child: _WallpaperDarknessLayer(
                key: ValueKey<String>('wallpaper-darkness-${output.name}'),
                darkness: assignment.darknessForOutput(output.name),
              ),
            ),
      ],
    );
  }
}

class _WallpaperDarknessLayer extends StatelessWidget {
  const _WallpaperDarknessLayer({
    super.key,
    required this.darkness,
  });

  final double darkness;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: ShellColors.launchSurface.withValues(alpha: darkness),
      ),
    );
  }
}

class _WallpaperImage extends StatelessWidget {
  const _WallpaperImage({
    required this.resource,
    this.alignment = Alignment.center,
  });

  final WallpaperResource resource;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: wallpaperImageProvider(resource),
      fit: BoxFit.cover,
      alignment: alignment,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (context, error, stackTrace) => Image(
        image: const AssetImage(defaultShellWallpaperAsset),
        fit: BoxFit.cover,
        alignment: alignment,
        filterQuality: FilterQuality.low,
        excludeFromSemantics: true,
      ),
    );
  }
}

class _ExpandingWallpaperHoleClipper extends CustomClipper<Path> {
  const _ExpandingWallpaperHoleClipper({
    required this.targetRect,
    required this.originFraction,
    required this.progress,
  });

  final Rect targetRect;
  final Offset originFraction;
  final double progress;

  @override
  Path getClip(Size size) {
    final bounds = targetRect.intersect(Offset.zero & size);
    final safeOrigin = Offset(
      bounds.left +
          (originFraction.dx.clamp(0.0, 1.0) * bounds.width).toDouble(),
      bounds.top +
          (originFraction.dy.clamp(0.0, 1.0) * bounds.height).toDouble(),
    );
    final farthestX = math.max(
      safeOrigin.dx - bounds.left,
      bounds.right - safeOrigin.dx,
    );
    final farthestY = math.max(
      safeOrigin.dy - bounds.top,
      bounds.bottom - safeOrigin.dy,
    );
    final radius = math.sqrt(
          farthestX * farthestX + farthestY * farthestY,
        ) *
        progress;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addOval(Rect.fromCircle(center: safeOrigin, radius: radius));
  }

  @override
  bool shouldReclip(covariant _ExpandingWallpaperHoleClipper oldClipper) {
    return oldClipper.targetRect != targetRect ||
        oldClipper.originFraction != originFraction ||
        oldClipper.progress != progress;
  }
}
