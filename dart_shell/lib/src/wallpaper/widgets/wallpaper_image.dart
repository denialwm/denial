import 'dart:io';

import 'package:flutter/widgets.dart';

import '../wallpaper.dart';

ImageProvider<Object> wallpaperImageProvider(WallpaperResource resource) {
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
    provider = wallpaperImageProvider(resource);
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
