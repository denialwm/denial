import 'package:test/test.dart';

import 'package:denial_flutter_sdk/src/wallpaper/wallpaper_pagination.dart';

void main() {
  late WallpaperPagination pagination;
  setUp(() => pagination = WallpaperPagination(['local', 'remote']));

  test('unknown bounds are not guessed and invalid pages are refused', () {
    expect(pagination.lastPage, isNull);
    expect(pagination.hasMore(1), isFalse);
    expect(pagination.shouldRequest('local', 1), isTrue);
    expect(pagination.shouldRequest('local', 0), isFalse);
    expect(pagination.shouldRequest('absent', 1), isFalse);
  });

  test('total is the largest reported end, only after all sources report', () {
    pagination.record(
      'local',
      const WallpaperPageInfo(page: 1, hasMore: false, lastPage: 1),
    );
    expect(pagination.lastPage, isNull);
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 1, hasMore: true, lastPage: 37),
    );
    expect(pagination.lastPage, 37);
    expect(pagination.hasMore(1), isTrue);
    expect(pagination.hasMore(36), isTrue);
    expect(pagination.hasMore(37), isFalse);
  });

  test(
    'short sources are skipped beyond their end but requested on return',
    () {
      pagination.record(
        'local',
        const WallpaperPageInfo(page: 1, hasMore: false, lastPage: 1),
      );
      pagination.record(
        'remote',
        const WallpaperPageInfo(page: 1, hasMore: true, lastPage: 3),
      );
      expect(pagination.shouldRequest('local', 2), isFalse);
      expect(pagination.shouldRequest('remote', 2), isTrue);
      expect(pagination.shouldRequest('local', 1), isTrue);
      expect(pagination.shouldRequest('remote', 4), isFalse);
    },
  );

  test('optional totals use hasMore without inventing a count', () {
    pagination.record(
      'local',
      const WallpaperPageInfo(page: 1, hasMore: false, lastPage: 1),
    );
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 1, hasMore: true),
    );
    expect(pagination.lastPage, isNull);
    expect(pagination.hasMore(1), isTrue);
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 2, hasMore: false),
    );
    expect(pagination.hasMore(2), isFalse);
    expect(pagination.shouldRequest('remote', 3), isFalse);
    expect(pagination.shouldRequest('remote', 1), isTrue);
  });

  test('reset forgets previous query bounds', () {
    pagination.record(
      'local',
      const WallpaperPageInfo(page: 1, hasMore: false, lastPage: 1),
    );
    pagination.reset();
    expect(pagination.lastPage, isNull);
    expect(pagination.shouldRequest('local', 2), isTrue);
  });

  test('new metadata can shrink or grow the listing without a fixed count', () {
    pagination.record(
      'local',
      const WallpaperPageInfo(page: 1, hasMore: false, lastPage: 1),
    );
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 1, hasMore: true, lastPage: 3),
    );
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 3, hasMore: false, lastPage: 1),
    );
    expect(pagination.lastPage, 1);
    expect(pagination.hasMore(3), isFalse);
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 1, hasMore: true, lastPage: 9),
    );
    expect(pagination.lastPage, 9);
    expect(pagination.hasMore(1), isTrue);
  });

  test('an unknown/failed source does not block a successful source Next', () {
    pagination.record(
      'remote',
      const WallpaperPageInfo(page: 1, hasMore: true, lastPage: 2),
    );
    expect(pagination.hasMore(1), isTrue);
    expect(pagination.lastPage, isNull);
    expect(pagination.shouldRequest('local', 2), isTrue);
  });

  test('empty source set has a single empty page', () {
    final empty = WallpaperPagination([]);
    expect(empty.lastPage, 1);
    expect(empty.hasMore(1), isFalse);
  });
}
