import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../wallpaper.dart';

ImageProvider<Object> wallpaperImageProvider(
  WallpaperResource resource, {
  required Size targetPixelSize,
}) {
  final provider = _rawWallpaperImageProvider(resource);
  if (!targetPixelSize.width.isFinite ||
      !targetPixelSize.height.isFinite ||
      targetPixelSize.width <= 0.0 ||
      targetPixelSize.height <= 0.0) {
    return provider;
  }
  return _CoverResizeImage(
    provider,
    width: targetPixelSize.width.ceil(),
    height: targetPixelSize.height.ceil(),
  );
}

ImageProvider<Object> _rawWallpaperImageProvider(WallpaperResource resource) {
  return switch (resource.kind) {
    WallpaperResourceKind.asset => AssetImage(resource.path),
    WallpaperResourceKind.file => FileImage(File(resource.path)),
  };
}

ImageProvider<Object>? wallpaperCandidateImageProvider(
  WallpaperCandidate candidate, {
  int? cacheHeight,
}) {
  ImageProvider<Object>? provider;
  final resource = candidate.resource;
  if (resource != null) {
    provider = _rawWallpaperImageProvider(resource);
  } else {
    final uri = candidate.previewUri;
    if (uri.scheme == 'https') {
      provider = NetworkImage(uri.toString());
    } else if (uri.scheme == 'file') {
      provider = FileImage(File.fromUri(uri));
    } else if (uri.scheme == 'asset' && uri.path.isNotEmpty) {
      provider = AssetImage(uri.path);
    }
  }
  if (provider == null || cacheHeight == null || cacheHeight <= 0) {
    return provider;
  }
  return ResizeImage.resizeIfNeeded(null, cacheHeight, provider);
}

@immutable
class _CoverResizeImageKey {
  const _CoverResizeImageKey(this.providerKey, this.width, this.height);

  final Object providerKey;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is _CoverResizeImageKey &&
      other.providerKey == providerKey &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(providerKey, width, height);
}

/// Decodes an image to the smallest size that can cover the target without
/// changing its aspect ratio. Unlike [ResizeImagePolicy.fit], neither axis can
/// end up smaller than the surface and be upscaled again by [BoxFit.cover].
@immutable
class _CoverResizeImage extends ImageProvider<_CoverResizeImageKey> {
  const _CoverResizeImage(
    this.imageProvider, {
    required this.width,
    required this.height,
  });

  final ImageProvider<Object> imageProvider;
  final int width;
  final int height;

  @override
  ImageStreamCompleter loadImage(
    _CoverResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        '_CoverResizeImage cannot wrap a provider that already resizes.',
      );
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final scale = math.min(
            1.0,
            math.max(width / intrinsicWidth, height / intrinsicHeight),
          );
          return ui.TargetImageSize(
            width: math.min(intrinsicWidth, (intrinsicWidth * scale).ceil()),
            height: math.min(intrinsicHeight, (intrinsicHeight * scale).ceil()),
          );
        },
      );
    }

    final completer = imageProvider.loadImage(key.providerKey, decodeCover);
    if (!kReleaseMode) {
      completer.debugLabel =
          '${completer.debugLabel} - CoverResized(${key.width}×${key.height})';
    }
    completer.addEphemeralErrorListener((exception, stackTrace) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
    });
    return completer;
  }

  @override
  Future<_CoverResizeImageKey> obtainKey(ImageConfiguration configuration) {
    return imageProvider
        .obtainKey(configuration)
        .then((key) => _CoverResizeImageKey(key, width, height));
  }

  @override
  bool operator ==(Object other) =>
      other is _CoverResizeImage &&
      other.imageProvider == imageProvider &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(imageProvider, width, height);
}
