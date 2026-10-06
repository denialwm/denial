import 'wallpaper.dart';

typedef WallpaperDownloadProgress = void Function(double progress);

abstract interface class WallpaperProvider {
  String get id;

  String get displayName;

  Future<WallpaperPage> search(WallpaperQuery query);

  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  });

  void dispose();
}

/// A wallpaper source whose image host can be checked independently of its
/// catalog API.
///
/// Keeping this separate from [WallpaperProvider] lets local and embedded
/// sources remain completely offline while the selector reports remote image
/// availability as an optional capability.
abstract interface class WallpaperImageServerProvider {
  Future<void> checkImageServerAvailability();
}
