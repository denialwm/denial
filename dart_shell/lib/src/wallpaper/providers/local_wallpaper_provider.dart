import 'dart:io';

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
          label: 'Default',
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
    final limited = items.take(query.limit).toList(growable: false);
    return WallpaperPage(
      items: limited,
      page: query.page,
      hasMore: items.length > limited.length,
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
