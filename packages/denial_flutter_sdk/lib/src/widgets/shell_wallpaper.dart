import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../state/display_layout.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/wallpaper.dart';
import '../wallpaper/widgets/wallpaper_image.dart';

class ShellWallpaper extends ConsumerWidget {
  const ShellWallpaper({
    super.key,
    this.onPainted,
    this.coveredOutputs = const <String>{},
  });

  static const String assetPath = defaultShellWallpaperAsset;

  /// Names of the outputs a client's own wallpaper covers, such as a live
  /// wallpaper. They are painted black and their picture is not loaded.
  final Set<String> coveredOutputs;

  /// Called from paint whenever the wallpaper repaints, with the boundary
  /// that holds it, for a consumer that captures the wallpaper.
  final ValueChanged<RenderRepaintBoundary>? onPainted;

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
        final spanPixelSize =
            displayLayout?.pixelSize ??
            spanRect.size * MediaQuery.devicePixelRatioOf(context);
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

        return _WallpaperBoundary(
          onPainted: onPainted,
          child: ColoredBox(
            color: context.shellColors.launchSurface,
            child: Stack(
              fit: StackFit.expand,
              children: [
                WallpaperScene(
                  assignment: wallpaper.assignment,
                  outputs: outputs,
                  spanRect: spanRect,
                  spanPixelSize: spanPixelSize,
                  coveredOutputs: coveredOutputs,
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
                        child: child,
                      );
                    },
                    child: WallpaperScene(
                      assignment: outgoing,
                      outputs: outputs,
                      spanRect: spanRect,
                      spanPixelSize: spanPixelSize,
                      coveredOutputs: coveredOutputs,
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

class _WallpaperBoundary extends SingleChildRenderObjectWidget {
  const _WallpaperBoundary({required this.onPainted, super.child});

  final ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWallpaperBoundary()..onPainted = onPainted;

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderWallpaperBoundary).onPainted = onPainted;
  }
}

class _RenderWallpaperBoundary extends RenderRepaintBoundary {
  ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPainted?.call(this);
  }
}

/// Paints one output's wallpaper in output-local coordinates.
///
/// Filtering the complete irregular desktop atlas lets a blur kernel sample
/// the empty space around rotated or offset monitors. A local, fully opaque
/// wallpaper gives security surfaces a real edge for every output instead.
class ShellOutputWallpaper extends ConsumerWidget {
  const ShellOutputWallpaper({required this.output, super.key});

  final DisplayOutput output;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assignment = ref.watch(
      wallpaperControllerProvider.select((state) => state.assignment),
    );
    final darkness = assignment.darknessForOutput(output.name);
    return RepaintBoundary(
      child: ColoredBox(
        color: context.shellColors.launchSurface,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _WallpaperImage(
              key: ValueKey<String>('wallpaper-image-output-${output.name}'),
              resource: assignment.forOutput(output.name),
              targetPixelSize: output.pixelSize,
              alignment: Alignment(
                assignment.alignmentForOutput(output.name).x,
                assignment.alignmentForOutput(output.name).y,
              ),
              zoom: assignment.zoomForOutput(output.name),
            ),
            if (darkness > 0)
              _WallpaperDarknessLayer(
                key: ValueKey<String>('wallpaper-darkness-${output.name}'),
                darkness: darkness,
              ),
          ],
        ),
      ),
    );
  }
}

class WallpaperScene extends StatelessWidget {
  const WallpaperScene({
    super.key,
    required this.assignment,
    required this.outputs,
    required this.spanRect,
    required this.spanPixelSize,
    this.coveredOutputs = const <String>{},
  });

  final WallpaperAssignment assignment;
  final List<DisplayOutput> outputs;
  final Rect spanRect;
  final Size spanPixelSize;

  /// Outputs painted black instead of their picture.
  final Set<String> coveredOutputs;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (outputs.isEmpty)
          Positioned.fromRect(
            rect: spanRect,
            child: _WallpaperImage(
              key: const ValueKey<String>('wallpaper-image-fallback'),
              resource: assignment.all,
              targetPixelSize: spanPixelSize,
              alignment: Alignment(
                assignment.spanAlignment.x,
                assignment.spanAlignment.y,
              ),
              zoom: assignment.zoom,
            ),
          ),
        for (final output in outputs)
          Positioned.fromRect(
            rect: output.logicalRect,
            child: coveredOutputs.contains(output.name)
                ? ColoredBox(
                    key: ValueKey<String>('wallpaper-covered-${output.name}'),
                    color: const Color(0xff000000),
                  )
                : _WallpaperImage(
                    key: ValueKey<String>(
                      'wallpaper-image-output-${output.name}',
                    ),
                    resource: assignment.forOutput(output.name),
                    targetPixelSize: output.pixelSize,
                    alignment: Alignment(
                      assignment.alignmentForOutput(output.name).x,
                      assignment.alignmentForOutput(output.name).y,
                    ),
                    zoom: assignment.zoomForOutput(output.name),
                  ),
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
          if (!coveredOutputs.contains(output.name) &&
              assignment.darknessForOutput(output.name) > 0.0)
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
  const _WallpaperDarknessLayer({super.key, required this.darkness});

  final double darkness;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: ShellMediaColors.darkness.withValues(alpha: darkness),
      ),
    );
  }
}

class _WallpaperImage extends StatefulWidget {
  const _WallpaperImage({
    super.key,
    required this.resource,
    required this.targetPixelSize,
    this.alignment = Alignment.center,
    this.zoom = 1.0,
  });

  final WallpaperResource resource;
  final Size targetPixelSize;
  final Alignment alignment;

  /// Enlarges the covering image about [alignment]'s point.
  final double zoom;

  /// The size to decode at: zoomed in steps of a half, so a zoom being
  /// changed decodes the picture again only now and then.
  Size get _decodeSize => targetPixelSize * ((zoom * 2).ceil() / 2);

  @override
  State<_WallpaperImage> createState() => _WallpaperImageState();
}

class _WallpaperImageState extends State<_WallpaperImage> {
  /// How long a wallpaper stays unchanged before its screen-sized copy is
  /// drawn. Until then it is painted from the decoded picture, which follows
  /// an alignment or zoom being changed at once.
  static const Duration _settleDelay = Duration(milliseconds: 400);

  late final ImageStreamListener _listener = ImageStreamListener(
    _sourceLoaded,
    onError: _sourceFailed,
  );
  WallpaperImageCacheLease? _cacheLease;
  ImageStream? _stream;

  /// The decoded picture, held only until the screen-sized copy exists.
  ImageInfo? _source;
  ScreenWallpaperLease? _screen;
  Timer? _settle;
  ScreenWallpaperKey? _settlingKey;
  bool _failed = false;

  ScreenWallpaperKey? get _key {
    final size = widget.targetPixelSize;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0.0 ||
        size.height <= 0.0) {
      return null;
    }
    return ScreenWallpaperKey(
      resource: widget.resource,
      width: size.width.ceil(),
      height: size.height.ceil(),
      alignment: widget.alignment,
      zoom: widget.zoom,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(covariant _WallpaperImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _releaseSource();
    _screen?.release();
    super.dispose();
  }

  void _update() {
    final key = _key;
    if (key != null && _screen?.key != key) {
      final drawn = ScreenWallpaperLease.find(key);
      if (drawn != null) {
        _screen?.release();
        _screen = drawn;
      }
    }
    if (key == null || _screen?.key != key) {
      _loadSource();
    }
    if (_source != null && key != _settlingKey) {
      _restartSettle();
    }
  }

  void _loadSource() {
    final provider = wallpaperImageProvider(
      widget.resource,
      targetPixelSize: widget._decodeSize,
    );
    final configuration = createLocalImageConfiguration(context);
    final lease = _cacheLease;
    if (lease != null &&
        lease.provider == provider &&
        lease.configuration == configuration) {
      return;
    }
    // The picture decoded before stays on screen until this one arrives.
    _stream?.removeListener(_listener);
    lease?.release();
    _failed = false;
    _cacheLease = WallpaperImageCacheLease(provider, configuration);
    _stream = provider.resolve(configuration)..addListener(_listener);
  }

  void _releaseSource() {
    _stream?.removeListener(_listener);
    _stream = null;
    _cacheLease?.release();
    _cacheLease = null;
    _source?.dispose();
    _source = null;
  }

  void _sourceLoaded(ImageInfo source, bool synchronousCall) {
    setState(() {
      _source?.dispose();
      _source = source;
      _failed = false;
    });
    _restartSettle();
  }

  void _sourceFailed(Object exception, StackTrace? stackTrace) {
    setState(() => _failed = true);
  }

  void _restartSettle() {
    _settlingKey = _key;
    _settle?.cancel();
    _settle = Timer(_settleDelay, _settled);
  }

  Future<void> _settled() async {
    _settle = null;
    final key = _key;
    final source = _source;
    if (key == null || source == null) {
      return;
    }
    if (_screen?.key == key) {
      setState(_releaseSource);
      return;
    }
    final ui.Image image;
    try {
      image = await drawScreenWallpaper(source.image, key);
    } on Object {
      // The decoded picture keeps being painted.
      return;
    }
    if (!mounted || _key != key || _settle != null) {
      image.dispose();
      return;
    }
    setState(() {
      _screen?.release();
      _screen = ScreenWallpaperLease.adopt(key, image);
      _releaseSource();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = _screen;
    if (screen != null && screen.key == _key) {
      return _screenImage(screen);
    }
    if (_failed) {
      return Image(
        image: wallpaperImageProvider(
          WallpaperResource.defaultWallpaper,
          targetPixelSize: widget.targetPixelSize,
        ),
        fit: BoxFit.cover,
        alignment: widget.alignment,
        filterQuality: FilterQuality.low,
        excludeFromSemantics: true,
      );
    }
    final source = _source;
    if (source == null) {
      // The wallpaper shown before stays until the next one is decoded.
      return screen == null ? const SizedBox.expand() : _screenImage(screen);
    }
    final image = RawImage(
      image: source.image,
      scale: source.scale,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      filterQuality: FilterQuality.low,
    );
    if (widget.zoom == 1.0) {
      return image;
    }
    return ClipRect(
      child: Transform.scale(
        scale: widget.zoom,
        alignment: widget.alignment,
        child: image,
      ),
    );
  }

  Widget _screenImage(ScreenWallpaperLease screen) {
    return RawImage(
      image: screen.image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.low,
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
    return wallpaperRevealClipPath(
      size: size,
      targetRect: targetRect,
      originFraction: originFraction,
      progress: progress,
    );
  }

  @override
  bool shouldReclip(covariant _ExpandingWallpaperHoleClipper oldClipper) {
    return oldClipper.targetRect != targetRect ||
        oldClipper.originFraction != originFraction ||
        oldClipper.progress != progress;
  }
}

/// The outgoing wallpaper outside the growing reveal circle, strictly clipped
/// to the output being changed.
Path wallpaperRevealClipPath({
  required Size size,
  required Rect targetRect,
  required Offset originFraction,
  required double progress,
}) {
  final bounds = targetRect.intersect(Offset.zero & size);
  if (bounds.isEmpty) {
    return Path();
  }
  final safeOrigin = Offset(
    bounds.left + (originFraction.dx.clamp(0.0, 1.0) * bounds.width).toDouble(),
    bounds.top + (originFraction.dy.clamp(0.0, 1.0) * bounds.height).toDouble(),
  );
  final farthestX = math.max(
    safeOrigin.dx - bounds.left,
    bounds.right - safeOrigin.dx,
  );
  final farthestY = math.max(
    safeOrigin.dy - bounds.top,
    bounds.bottom - safeOrigin.dy,
  );
  final radius =
      math.sqrt(farthestX * farthestX + farthestY * farthestY) *
      progress.clamp(0.0, 1.0);
  return Path.combine(
    PathOperation.difference,
    Path()..addRect(bounds),
    Path()..addOval(Rect.fromCircle(center: safeOrigin, radius: radius)),
  );
}
