import 'dart:async';
import 'dart:io';

import 'package:denial_flutter_sdk/src/launcher/runtime_paths.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

WallpaperCandidate candidate(String source, String id) => WallpaperCandidate(
  id: id,
  providerId: source,
  label: id,
  previewUri: Uri.parse('asset:test'),
  width: 0,
  height: 0,
);

class Request {
  Request(this.query);
  final WallpaperQuery query;
  final result = Completer<WallpaperPage>();
  void complete(String source, {int lastPage = 3, bool empty = false}) {
    result.complete(
      WallpaperPage(
        items: empty ? [] : [candidate(source, '${query.text}:${query.page}')],
        page: query.page,
        hasMore: query.page < lastPage,
        lastPage: lastPage,
      ),
    );
  }
}

class Source implements WallpaperProvider {
  Source(this.id);
  @override
  final String id;
  final requests = <Request>[];
  @override
  String get displayName => id;
  @override
  Future<WallpaperPage> search(WallpaperQuery query) {
    final request = Request(query);
    requests.add(request);
    return request.result.future;
  }

  @override
  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  }) async => WallpaperResource.defaultWallpaper;
  @override
  void dispose() {}
}

class MemoryStore extends WallpaperStore {
  MemoryStore()
    : super(RuntimePaths(environment: const {'HOME': '/nonexistent'}));
  @override
  Future<Stream<FileSystemEvent>> watch() async => const Stream.empty();
  @override
  Future<void> write(WallpaperAssignment assignment) async {}
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('controller catalog pagination', () {
    late Source local;
    late Source remote;
    late ProviderContainer container;
    late WallpaperController controller;
    WallpaperExperienceState state() =>
        container.read(wallpaperControllerProvider);
    setUp(() {
      local = Source('local');
      remote = Source('remote');
      container = ProviderContainer(
        overrides: [
          wallpaperSourcesProvider.overrideWithValue([local, remote]),
          wallpaperStoreProvider.overrideWithValue(MemoryStore()),
          initialWallpaperAssignmentProvider.overrideWithValue(
            WallpaperAssignment.initial(),
          ),
        ],
      );
      controller = container.read(wallpaperControllerProvider.notifier);
      controller.openSelector(targetPixelSize: const Size(1920, 1080));
    });
    tearDown(() => container.dispose());
    Future<void> firstPage({int localEnd = 1, int remoteEnd = 3}) async {
      // Reverse completion order must not reverse source ordering.
      remote.requests.last.complete('remote', lastPage: remoteEnd);
      local.requests.last.complete('local', lastPage: localEnd);
      await settle();
    }

    test(
      'Next/Previous replace results, skip exhausted sources, preserve order',
      () async {
        await firstPage();
        expect(state().candidates.map((c) => c.providerId), [
          'local',
          'remote',
        ]);
        expect(state().lastPage, 3);
        controller.nextPage();
        controller.nextPage();
        controller.submitQuery();
        expect(remote.requests.length, 2);
        expect(local.requests.length, 1);
        expect(state().page, 2);
        expect(state().loading, isTrue);
        expect(state().candidates, isEmpty);
        remote.requests.last.complete('remote');
        await settle();
        expect(state().candidates.single.id, ':2');
        controller.previousPage();
        expect(local.requests.last.query.page, 1);
        await firstPage();
        expect(state().page, 1);
        expect(state().candidates.map((c) => c.providerId), [
          'local',
          'remote',
        ]);
        controller.previousPage();
        controller.submitQuery();
        expect(local.requests.length, 2);
        expect(remote.requests.length, 3);
      },
    );

    test(
      'query invalidates page results before debounce, submit runs only once',
      () async {
        await firstPage();
        controller.nextPage();
        final stale = remote.requests.last;
        controller.setQuery('landscape');
        expect(state().page, 1);
        expect(state().lastPage, isNull);
        stale.complete('remote');
        await settle();
        expect(state().candidates, isEmpty);
        expect(state().loading, isTrue);
        controller.submitQuery();
        controller.submitQuery();
        expect(remote.requests.length, 3);
        expect(remote.requests.last.query.text, 'landscape');
        await firstPage(remoteEnd: 2);
        expect(state().candidates.last.id, 'landscape:1');
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(remote.requests.length, 3);
      },
    );

    test('changing the resolution filter resets to page 1', () async {
      await firstPage();
      controller.nextPage();
      final stale = remote.requests.last;
      controller.selectTarget(
        target: const WallpaperTarget.all(),
        targetPixelSize: const Size(2560, 1440),
      );
      stale.complete('remote');
      await settle();
      expect(state().page, 1);
      expect(state().candidates, isEmpty);
      expect(
        remote.requests.last.query.targetPixelSize,
        const Size(2560, 1440),
      );
      await firstPage();
      expect(state().candidates.last.id, ':1');
    });

    test(
      'partial failure remains visible/retryable; retry stays on current page',
      () async {
        local.requests.last.complete('local', lastPage: 2);
        remote.requests.last.result.completeError(
          const SocketException('offline'),
        );
        await settle();
        expect(state().candidates.single.providerId, 'local');
        expect(state().error, isNotNull);
        expect(state().loading, isFalse);
        controller.retryOnlineWallpapers();
        controller.retryOnlineWallpapers();
        expect(remote.requests.length, 2);
        await firstPage(localEnd: 2);
        controller.nextPage();
        local.requests.last.complete('local', lastPage: 2);
        remote.requests.last.result.completeError(
          const SocketException('offline'),
        );
        await settle();
        controller.nextPage();
        expect(state().page, 2);
        controller.retryOnlineWallpapers();
        expect(remote.requests.last.query.page, 2);
        local.requests.last.complete('local', lastPage: 2);
        remote.requests.last.complete('remote');
        await settle();
        expect(state().error, isNull);
        expect(state().hasMore, isTrue);
      },
    );

    test('empty final page disables Next; Previous still works', () async {
      await firstPage(remoteEnd: 2);
      controller.nextPage();
      remote.requests.last.complete('remote', lastPage: 2, empty: true);
      await settle();
      expect(state().candidates, isEmpty);
      expect(state().hasMore, isFalse);
      controller.nextPage();
      expect(remote.requests.length, 2);
      controller.previousPage();
      await firstPage(remoteEnd: 2);
      expect(state().page, 1);
    });

    test(
      'shrinking API bounds correct the page once without walking/fetch-all',
      () async {
        await firstPage();
        controller.nextPage();
        remote.requests.last.complete('remote');
        await settle();
        controller.nextPage();
        remote.requests.last.complete('remote', lastPage: 1, empty: true);
        await settle();
        expect(state().page, 1);
        expect(remote.requests.map((r) => r.query.page), [1, 2, 3, 1]);
        await firstPage(remoteEnd: 1);
        expect(state().hasMore, isFalse);
      },
    );

    test(
      'close ignores pending results and reopening starts at page 1',
      () async {
        await firstPage();
        controller.nextPage();
        final stale = remote.requests.last;
        controller.closeSelector();
        stale.complete('remote');
        await settle();
        expect(state().selectorVisible, isFalse);
        expect(state().candidates, isEmpty);
        controller.openSelector(targetPixelSize: const Size(1920, 1080));
        expect(state().page, 1);
        await firstPage();
      },
    );

    test(
      'repeated shrinking stops automatic requests and leaves valid Retry',
      () async {
        await firstPage();
        controller.nextPage();
        remote.requests.last.complete('remote');
        await settle();
        controller.nextPage();
        remote.requests.last.complete('remote', lastPage: 2, empty: true);
        await settle();
        expect(state().page, 2);
        remote.requests.last.complete('remote', lastPage: 1, empty: true);
        await settle();
        expect(state().page, 1);
        expect(state().lastPage, 1);
        expect(state().error, isNotNull);
        expect(state().loading, isFalse);
        expect(remote.requests.map((r) => r.query.page), [1, 2, 3, 2]);
        controller.retryOnlineWallpapers();
        expect(remote.requests.last.query.page, 1);
        await firstPage(remoteEnd: 1);
        expect(state().error, isNull);
      },
    );

    test(
      'download materialization remains applied to the current result set',
      () async {
        await firstPage();
        controller.nextPage();
        remote.requests.last.complete('remote');
        await settle();
        final item = state().candidates.single;
        final resource = await controller.resolveCandidate(item);
        expect(resource, WallpaperResource.defaultWallpaper);
        expect(state().candidates.single.resource, resource);
        expect(state().downloadingKey, isNull);
      },
    );
  });

  test(
    'local pages slice the sorted library and default only occurs once',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'wallpaper-pagination-',
      );
      addTearDown(() => dir.delete(recursive: true));
      for (var i = 24; i >= 0; i--) {
        await File('${dir.path}/image-${i.toString().padLeft(2, '0')}.jpg')
            .writeAsString('fixture');
      }
      await File('${dir.path}/ignored.txt').writeAsString('fixture');
      final source = LocalWallpaperProvider(directory: dir);
      WallpaperQuery query(int page, {String text = ''}) => WallpaperQuery(
        text: text,
        page: page,
        limit: 24,
        targetPixelSize: Size.zero,
      );
      final first = await source.search(query(1));
      final second = await source.search(query(2));
      expect(first.items.length, 24);
      expect(first.items.first.id, 'default');
      expect(first.lastPage, 2);
      expect(first.hasMore, isTrue);
      expect(second.items.map((c) => c.label), ['image-23', 'image-24']);
      expect(second.hasMore, isFalse);
      expect(
        {
          ...first.items.map((c) => c.key),
          ...second.items.map((c) => c.key),
        }.length,
        26,
      );
      expect((await source.search(query(3))).items, isEmpty);
      final filtered = await source.search(query(1, text: 'image-24'));
      expect(filtered.items.single.label, 'image-24');
      expect(filtered.lastPage, 1);
    },
  );

  group('Wallhaven actual pagination metadata', () {
    WallpaperPage parse(Map<String, dynamic> response, {int page = 1}) =>
        WallhavenWallpaperProvider.parsePageResponse(
          response,
          providerId: 'wallhaven',
          query: WallpaperQuery(
            text: '',
            page: page,
            limit: 24,
            targetPixelSize: Size.zero,
          ),
        );
    test('uses server current_page/last_page, including an empty listing', () {
      final result = parse({
        'data': [],
        'meta': {'current_page': 2, 'last_page': 37},
      }, page: 2);
      expect(result.page, 2);
      expect(result.lastPage, 37);
      expect(result.hasMore, isTrue);
      expect(
        parse({
          'data': [],
          'meta': {'current_page': 1, 'last_page': 0},
        }).lastPage,
        1,
      );
    });
    test(
      'missing, invalid and mismatched metadata is an error, not page 1',
      () {
        for (final meta in [
          null,
          {},
          {'current_page': 2, 'last_page': 3},
          {'current_page': 1, 'last_page': '3'},
          {'current_page': 1, 'last_page': -1},
        ]) {
          expect(
            () => parse({'data': [], 'meta': meta}),
            throwsFormatException,
          );
        }
      },
    );
  });
}
