/// Pagination metadata, independent of image decoding and Flutter.
class WallpaperPageInfo {
  const WallpaperPageInfo({
    required this.page,
    required this.hasMore,
    this.lastPage,
  });

  final int page;
  final bool hasMore;
  final int? lastPage;
}

/// Retains only source bounds, never candidates from previous pages.
/// Sources keep their order and share a page number, but a shorter source is
/// not queried beyond its known end. A failed/unknown source has no guessed end.
class WallpaperPagination {
  WallpaperPagination(Iterable<String> sourceIds)
    : _sourceIds = Set<String>.of(sourceIds);

  final Set<String> _sourceIds;
  final Map<String, WallpaperPageInfo> _bounds = {};

  void reset() => _bounds.clear();

  void record(String sourceId, WallpaperPageInfo info) {
    if (_sourceIds.contains(sourceId)) _bounds[sourceId] = info;
  }

  bool shouldRequest(String sourceId, int page) {
    if (page < 1 || !_sourceIds.contains(sourceId)) return false;
    final info = _bounds[sourceId];
    if (info == null) return true;
    final end = info.lastPage ?? (info.hasMore ? null : info.page);
    return end == null || page <= end;
  }

  bool hasMore(int page) => _bounds.values.any(
    (info) => info.lastPage != null
        ? page < info.lastPage!
        : info.page == page && info.hasMore,
  );

  /// An exact total is shown only when every source has supplied one.
  int? get lastPage {
    if (_sourceIds.isEmpty) return 1;
    var maximum = 1;
    for (final id in _sourceIds) {
      final end = _bounds[id]?.lastPage;
      if (end == null) return null;
      if (end > maximum) maximum = end;
    }
    return maximum;
  }
}
