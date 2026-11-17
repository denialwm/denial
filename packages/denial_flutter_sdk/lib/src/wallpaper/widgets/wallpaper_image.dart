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

@immutable
class _WallpaperImageCacheUse {
  const _WallpaperImageCacheUse(this.provider, this.configuration);

  final ImageProvider<Object> provider;
  final ImageConfiguration configuration;

  @override
  bool operator ==(Object other) =>
      other is _WallpaperImageCacheUse &&
      other.provider == provider &&
      other.configuration == configuration;

  @override
  int get hashCode => Object.hash(provider, configuration);
}

/// Keeps a rendered wallpaper variant alive while immediately evicting its
/// decoded cache entry after the final wallpaper scene releases it.
@internal
class WallpaperImageCacheLease {
  WallpaperImageCacheLease(this.provider, this.configuration)
    : _use = _WallpaperImageCacheUse(provider, configuration) {
    _WallpaperImageCacheLeases.retain(_use);
  }

  final ImageProvider<Object> provider;
  final ImageConfiguration configuration;
  final _WallpaperImageCacheUse _use;
  bool _released = false;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _WallpaperImageCacheLeases.release(_use);
  }
}

class _WallpaperImageCacheLeases {
  static final Map<_WallpaperImageCacheUse, int> _counts =
      <_WallpaperImageCacheUse, int>{};

  static void retain(_WallpaperImageCacheUse use) {
    _counts.update(use, (count) => count + 1, ifAbsent: () => 1);
  }

  static void release(_WallpaperImageCacheUse use) {
    final count = _counts[use];
    assert(count != null && count > 0);
    if (count == null) {
      return;
    }
    if (count > 1) {
      _counts[use] = count - 1;
      return;
    }
    _counts.remove(use);
    scheduleMicrotask(() async {
      if (_counts.containsKey(use)) {
        return;
      }
      try {
        final key = await use.provider.obtainKey(use.configuration);
        if (!_counts.containsKey(use)) {
          PaintingBinding.instance.imageCache.evict(key, includeLive: false);
        }
      } on Object {
        // A provider which cannot produce a key has nothing cacheable to evict.
      }
    });
  }
}

/// The part of a decoded wallpaper its screen shows: [BoxFit.cover] placed by
/// [alignment], then enlarged by [zoom] about the same point.
Rect wallpaperSourceRect({
  required Size imageSize,
  required Size screenSize,
  required Alignment alignment,
  double zoom = 1.0,
}) {
  final covered = applyBoxFit(BoxFit.cover, imageSize, screenSize).source;
  final shown = alignment.inscribe(covered, Offset.zero & imageSize);
  if (zoom <= 1.0) {
    return shown;
  }
  return alignment.inscribe(shown.size / zoom, shown);
}

/// One wallpaper as one screen shows it.
@immutable
class ScreenWallpaperKey {
  const ScreenWallpaperKey({
    required this.resource,
    required this.width,
    required this.height,
    required this.alignment,
    required this.zoom,
  });

  final WallpaperResource resource;

  /// The screen's size in physical pixels.
  final int width;
  final int height;
  final Alignment alignment;
  final double zoom;

  @override
  bool operator ==(Object other) =>
      other is ScreenWallpaperKey &&
      other.resource == resource &&
      other.width == width &&
      other.height == height &&
      other.alignment == alignment &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(resource, width, height, alignment, zoom);
}

/// Draws the part of [source] that [key]'s screen shows, at that screen's
/// size. The decoded picture can be far larger than the screen: a wide
/// picture on an upright screen keeps every column the screen never shows.
@internal
Future<ui.Image> drawScreenWallpaper(
  ui.Image source,
  ScreenWallpaperKey key,
) async {
  final screen = Size(key.width.toDouble(), key.height.toDouble());
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    source,
    wallpaperSourceRect(
      imageSize: Size(source.width.toDouble(), source.height.toDouble()),
      screenSize: screen,
      alignment: key.alignment,
      zoom: key.zoom,
    ),
    Offset.zero & screen,
    Paint()..filterQuality = FilterQuality.low,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(key.width, key.height);
  } finally {
    picture.dispose();
  }
}

class _ScreenWallpaper {
  _ScreenWallpaper(this.image);

  final ui.Image image;
  int users = 1;
}

/// A hold on a wallpaper drawn at its screen's size. Every scene showing the
/// same wallpaper on the same screen shares one copy, which is disposed once
/// the last scene lets go of it.
@internal
class ScreenWallpaperLease {
  ScreenWallpaperLease._(this.key, this.image);

  static final Map<ScreenWallpaperKey, _ScreenWallpaper> _drawn =
      <ScreenWallpaperKey, _ScreenWallpaper>{};

  final ScreenWallpaperKey key;
  final ui.Image image;
  bool _released = false;

  /// The copy already drawn for [key], or null.
  static ScreenWallpaperLease? find(ScreenWallpaperKey key) {
    final drawn = _drawn[key];
    if (drawn == null) {
      return null;
    }
    drawn.users += 1;
    return ScreenWallpaperLease._(key, drawn.image);
  }

  /// Makes [image] the copy for [key]; when another scene drew one first,
  /// [image] is disposed and that one is shared.
  static ScreenWallpaperLease adopt(ScreenWallpaperKey key, ui.Image image) {
    final drawn = find(key);
    if (drawn != null) {
      image.dispose();
      return drawn;
    }
    _drawn[key] = _ScreenWallpaper(image);
    return ScreenWallpaperLease._(key, image);
  }

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    final drawn = _drawn[key];
    if (drawn == null) {
      return;
    }
    drawn.users -= 1;
    if (drawn.users > 0) {
      return;
    }
    // A scene taking this wallpaper over in the same build keeps it.
    scheduleMicrotask(() {
      if (drawn.users == 0 && identical(_drawn[key], drawn)) {
        _drawn.remove(key);
        drawn.image.dispose();
      }
    });
  }
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
