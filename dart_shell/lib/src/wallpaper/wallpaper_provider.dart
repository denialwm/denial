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
