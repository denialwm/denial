import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import 'wallpaper_strip.dart';

/// Deterministic geometry for the wallpaper selector's uncropped gallery.
///
/// Every cell shares the target display's aspect ratio, so a wallpaper made
/// for that display fills its cell and any other shape is letterboxed whole.
/// Candidate dimensions are never consulted: local files report none, and
/// probing them would mean reading every image before it is shown.
@immutable
class WallpaperGalleryLayout {
  const WallpaperGalleryLayout({
    required this.columns,
    required this.tileAspectRatio,
    required this.tileWidth,
    required this.horizontalInset,
  });

  factory WallpaperGalleryLayout.resolve({
    required Size viewport,
    required double targetAspectRatio,
  }) {
    final width = _finiteNonNegative(viewport.width);
    final height = _finiteNonNegative(viewport.height);
    final aspectRatio = sanitizeAspectRatio(targetAspectRatio);

    final minimumWidth = minimumTileWidth(aspectRatio);
    var inset = (width * 0.05).clamp(16.0, 72.0).toDouble();
    if (width - inset * 2.0 > maximumContentWidth) {
      inset = (width - maximumContentWidth) / 2.0;
    }
    if (width - inset * 2.0 < minimumWidth) {
      inset = 0.0;
    }
    final contentWidth = width - inset * 2.0;

    var columns = ((contentWidth + spacing) / (minimumWidth + spacing)).floor();
    if (height > 0.0) {
      // Keep at least one full row visible in short viewports.
      final maximumTileWidth = height * maximumTileHeightFraction * aspectRatio;
      final requiredColumns =
          ((contentWidth + spacing) / (maximumTileWidth + spacing)).ceil();
      columns = math.max(columns, requiredColumns);
    }
    columns = columns.clamp(1, maximumColumns);
    final tileWidth = math.max(
      0.0,
      (contentWidth - spacing * (columns - 1)) / columns,
    );
    return WallpaperGalleryLayout(
      columns: columns,
      tileAspectRatio: aspectRatio,
      tileWidth: tileWidth,
      horizontalInset: inset,
    );
  }

  static const double spacing = 14.0;
  static const double defaultAspectRatio = 16.0 / 9.0;
  static const double minimumAspectRatio = 0.5;
  static const double maximumAspectRatio = 2.4;

  /// Cells keep roughly this logical area regardless of orientation, so a
  /// portrait display gets narrower columns instead of tiny landscape tiles.
  static const double minimumTileArea = 256.0 * 144.0;
  static const double maximumTileHeightFraction = 0.85;
  static const int maximumColumns = 6;
  static const double maximumContentWidth = 1680.0;

  /// Decode sizes round up to this step so small resizes share cache entries.
  static const int decodeStep = 64;

  /// Upper bound for either decoded preview dimension, in physical pixels.
  static const int maximumDecodeExtent = 1024;

  final int columns;
  final double tileAspectRatio;
  final double tileWidth;
  final double horizontalInset;

  double get tileHeight => tileWidth / tileAspectRatio;

  double get rowExtent => tileHeight + spacing;

  static double sanitizeAspectRatio(double aspectRatio) {
    if (!aspectRatio.isFinite || aspectRatio <= 0.0) {
      return defaultAspectRatio;
    }
    return aspectRatio.clamp(minimumAspectRatio, maximumAspectRatio).toDouble();
  }

  static double minimumTileWidth(double aspectRatio) =>
      math.sqrt(minimumTileArea * sanitizeAspectRatio(aspectRatio));

  int rowCount(int itemCount) =>
      itemCount <= 0 ? 0 : (itemCount + columns - 1) ~/ columns;

  double contentHeight(int itemCount) {
    final rows = rowCount(itemCount);
    return rows == 0 ? 0.0 : rows * tileHeight + (rows - 1) * spacing;
  }

  /// Scroll offset that centers [index]'s row, clamped to the scroll extent.
  double scrollOffsetFor(
    int index, {
    required int itemCount,
    required double viewportHeight,
  }) {
    if (itemCount <= 0) {
      return 0.0;
    }
    final viewport = _finiteNonNegative(viewportHeight);
    final row = index.clamp(0, itemCount - 1) ~/ columns;
    final centered = row * rowExtent - (viewport - tileHeight) / 2.0;
    final maximum = math.max(0.0, contentHeight(itemCount) - viewport);
    return centered.clamp(0.0, maximum).toDouble();
  }

  /// Physical bounds for decoding one preview with [ResizeImagePolicy.fit].
  ///
  /// The decoded image fits inside these bounds without cropping or
  /// upscaling, so memory per tile never exceeds
  /// [maximumDecodeExtent] squared, whatever the source resolution.
  ({int width, int height}) decodeSize(double devicePixelRatio) {
    final scale = devicePixelRatio.isFinite && devicePixelRatio > 0.0
        ? devicePixelRatio
        : 1.0;
    return (
      width: _decodeExtent(tileWidth * scale),
      height: _decodeExtent(tileHeight * scale),
    );
  }

  static int _decodeExtent(double physical) {
    if (!physical.isFinite || physical <= decodeStep) {
      return decodeStep;
    }
    final stepped = (physical / decodeStep).ceil() * decodeStep;
    return math.min(stepped, maximumDecodeExtent);
  }

  static double _finiteNonNegative(double value) =>
      value.isFinite && value > 0.0 ? value : 0.0;

  @override
  bool operator ==(Object other) =>
      other is WallpaperGalleryLayout &&
      other.columns == columns &&
      other.tileAspectRatio == tileAspectRatio &&
      other.tileWidth == tileWidth &&
      other.horizontalInset == horizontalInset;

  @override
  int get hashCode =>
      Object.hash(columns, tileAspectRatio, tileWidth, horizontalInset);
}

/// An optional vertically scrolling alternative to the narrow strips that
/// shows every wallpaper whole.
class WallpaperGallery extends StatefulWidget {
  const WallpaperGallery({
    super.key,
    required this.candidates,
    required this.targetAspectRatio,
    required this.initialIndex,
    required this.current,
    required this.downloadingKey,
    required this.downloadProgress,
    required this.onTapUp,
  });

  final List<WallpaperCandidate> candidates;
  final double targetAspectRatio;
  final int initialIndex;
  final WallpaperResource? current;
  final String? downloadingKey;
  final double downloadProgress;
  final void Function(int index, Offset globalPosition) onTapUp;

  @override
  State<WallpaperGallery> createState() => _WallpaperGalleryState();
}

class _WallpaperGalleryState extends State<WallpaperGallery> {
  ScrollController? _scrollController;

  @override
  void dispose() {
    _scrollController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final candidates = widget.candidates;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = WallpaperGalleryLayout.resolve(
          viewport: constraints.biggest,
          targetAspectRatio: widget.targetAspectRatio,
        );
        final scrollController = _scrollController ??= ScrollController(
          initialScrollOffset: layout.scrollOffsetFor(
            widget.initialIndex,
            itemCount: candidates.length,
            viewportHeight: constraints.maxHeight,
          ),
        );
        final decodeSize = layout.decodeSize(
          MediaQuery.devicePixelRatioOf(context),
        );
        return GridView.builder(
          controller: scrollController,
          padding: EdgeInsets.symmetric(horizontal: layout.horizontalInset),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: layout.columns,
            mainAxisSpacing: WallpaperGalleryLayout.spacing,
            crossAxisSpacing: WallpaperGalleryLayout.spacing,
            childAspectRatio: layout.tileAspectRatio,
          ),
          itemCount: candidates.length,
          itemBuilder: (context, index) {
            final candidate = candidates[index];
            return _WallpaperGalleryTile(
              candidate: candidate,
              current: candidate.resource == widget.current,
              downloading: widget.downloadingKey == candidate.key,
              downloadProgress: widget.downloadProgress,
              decodeWidth: decodeSize.width,
              decodeHeight: decodeSize.height,
              onTapUp: (origin) => widget.onTapUp(index, origin),
            );
          },
        );
      },
    );
  }
}

class _WallpaperGalleryTile extends StatefulWidget {
  const _WallpaperGalleryTile({
    required this.candidate,
    required this.current,
    required this.downloading,
    required this.downloadProgress,
    required this.decodeWidth,
    required this.decodeHeight,
    required this.onTapUp,
  });

  final WallpaperCandidate candidate;
  final bool current;
  final bool downloading;
  final double downloadProgress;
  final int decodeWidth;
  final int decodeHeight;
  final ValueChanged<Offset> onTapUp;

  @override
  State<_WallpaperGalleryTile> createState() => _WallpaperGalleryTileState();
}

class _WallpaperGalleryTileState extends State<_WallpaperGalleryTile> {
  static const double _radius = 16.0;

  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final label = wallpaperCandidateLabel(context, widget.candidate);
    final source = wallpaperCandidateImageProvider(widget.candidate);
    final image = source == null
        ? null
        : ResizeImage(
            source,
            width: widget.decodeWidth,
            height: widget.decodeHeight,
            policy: ResizeImagePolicy.fit,
          );
    final borderRadius = context.shellTheme.borderRadius(_radius);
    return Semantics(
      button: true,
      selected: widget.current,
      label: context.l10n.wallpaperApplyCandidate(label),
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => widget.onTapUp(details.globalPosition),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                border: Border.all(
                  color: widget.current || _hovered
                      ? accent.primary
                      : context.shellColors.hairline,
                  width: widget.current ? 3.0 : 1.0,
                ),
              ),
              child: ColoredBox(
                color: context.shellColors.surfaceContainerHigh,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (image != null)
                      Image(
                        image: image,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                        errorBuilder: (context, error, stackTrace) =>
                            const WallpaperTilePlaceholder(
                              icon: Icons.broken_image_rounded,
                            ),
                      )
                    else
                      const WallpaperTilePlaceholder(icon: Icons.image_rounded),
                    if (widget.downloading)
                      WallpaperDownloadOverlay(
                        progress: widget.downloadProgress,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
