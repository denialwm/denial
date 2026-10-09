import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../wallpaper.dart';
import '../wallpaper_provider.dart';

class LocalWallpaperProvider implements WallpaperProvider {
  const LocalWallpaperProvider({required this._directory});

  final Directory _directory;

  @override
  String get id => 'local';

  @override
  String get displayName => 'On this device';

  @override
  Future<WallpaperPage> search(WallpaperQuery query) async {
    final normalizedQuery = query.text.trim().toLowerCase();
    final bundledDefaultName = p
        .basename(defaultShellWallpaperAsset)
        .toLowerCase();
    final items = <WallpaperCandidate>[
      if (normalizedQuery.isEmpty || 'default'.contains(normalizedQuery))
        WallpaperCandidate(
          id: 'default',
          providerId: id,
          label: 'default',
          previewUri: Uri.parse('asset:$defaultShellWallpaperAsset'),
          width: 0,
          height: 0,
          resource: WallpaperResource.defaultWallpaper,
        ),
    ];

    try {
      if (await _directory.exists()) {
        await for (final entity in _directory.list(followLinks: false)) {
          if (entity is! File || !_isWallpaperFile(entity.path)) {
            continue;
          }
          final name = p.basename(entity.path);
          if (name.toLowerCase() == bundledDefaultName) {
            continue;
          }
          if (normalizedQuery.isNotEmpty &&
              !name.toLowerCase().contains(normalizedQuery)) {
            continue;
          }
          final resource = WallpaperResource.file(entity.path);
          items.add(
            WallpaperCandidate(
              id: entity.path,
              providerId: id,
              label: p.basenameWithoutExtension(name),
              previewUri: Uri.file(entity.path),
              width: 0,
              height: 0,
              resource: resource,
            ),
          );
        }
      }
    } on FileSystemException {
      // The bundled default remains available when the user library is absent.
    }

    final defaultItem = items.isNotEmpty && items.first.id == 'default'
        ? items.removeAt(0)
        : null;
    items.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    if (defaultItem != null) {
      items.insert(0, defaultItem);
    }
    final page = math.max(1, query.page);
    final limit = math.max(1, query.limit);
    final start = (page - 1) * limit;
    final limited = items.skip(start).take(limit).toList(growable: false);
    final lastPage = math.max(1, (items.length / limit).ceil());
    return WallpaperPage(
      items: limited,
      page: page,
      hasMore: page < lastPage,
      lastPage: lastPage,
    );
  }

  @override
  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  }) async {
    final resource = candidate.resource;
    if (resource == null) {
      throw StateError('Local wallpaper has no materialized resource');
    }
    onProgress?.call(1.0);
    return resource;
  }

  @override
  void dispose() {}
}

const _wallpaperExtensions = <String>{'.jpg', '.jpeg', '.png', '.webp'};

bool _isWallpaperFile(String path) {
  return _wallpaperExtensions.contains(p.extension(path).toLowerCase());
}
