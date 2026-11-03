import 'dart:io';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:flutter_test/flutter_test.dart';

DesktopApp _app(String id) => DesktopApp(
  id: id,
  name: id,
  exec: id,
  desktopPath: '/usr/share/applications/$id.desktop',
  categories: const <String>[],
);

HomeGridItem _item(String id) => HomeGridItem.app(_app(id));

List<String?> _ids(List<HomeGridItem?> slots) => [
  for (final item in slots) item?.id,
];

void main() {
  const pageSize = 16;

  setUp(() => HomeGridLayout.columns = 4);

  group('folders', () {
    test('an app dropped on an app makes a folder in the target cell', () {
      final slots = [_item('a'), null, _item('b')];
      final next = HomeGridLayout.merge(
        slots,
        0,
        2,
        folderId: 'folder:x',
        folderName: 'Games',
      )!;
      expect(next[0], isNull);
      final folder = next[2]!;
      expect(folder.isFolder, isTrue);
      expect(folder.folderName, 'Games');
      expect(folder.folderApps.map((item) => item.id), ['app:b', 'app:a']);
    });

    test('an app dropped on a folder joins it at the end', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      final next = HomeGridLayout.merge(
        [folder, _item('c')],
        1,
        0,
        folderId: 'folder:unused',
        folderName: 'unused',
      )!;
      expect(next[1], isNull);
      expect(next[0]!.id, 'folder:x');
      expect(next[0]!.folderApps.map((item) => item.id), [
        'app:a',
        'app:b',
        'app:c',
      ]);
    });

    test('widgets and folders never merge into anything', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      final slots = [HomeGridItem.clock(), null, _item('c'), folder];
      expect(HomeGridLayout.canMerge(slots, 0, 2), isFalse);
      expect(HomeGridLayout.canMerge(slots, 3, 2), isFalse);
      expect(HomeGridLayout.canMerge(slots, 2, 0), isFalse);
      expect(HomeGridLayout.canMerge(slots, 2, 3), isTrue);
    });

    test('a folder left with one app becomes that app', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      final next = HomeGridLayout.moveOutOfFolder(
        [folder],
        0,
        'app:a',
        5,
        pageSize,
      )!;
      expect(_ids(next), ['app:b', null, null, null, null, 'app:a']);
    });

    test('an app moved out of a folder takes the nearest free cell', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final next = HomeGridLayout.moveOutOfFolder(
        [folder, _item('d'), null],
        0,
        'app:c',
        1,
        pageSize,
      )!;
      expect(_ids(next), ['folder:x', 'app:d', 'app:c']);
      expect(next[0]!.folderApps.length, 2);
    });

    test('an app moves from one folder into another', () {
      final first = HomeGridItem.folder(
        id: 'folder:1',
        name: 'One',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final second = HomeGridItem.folder(
        id: 'folder:2',
        name: 'Two',
        apps: [_item('d'), _item('e')],
      );
      final next = HomeGridLayout.moveFromFolderInto(
        [first, second],
        0,
        'app:a',
        1,
        folderId: 'folder:3',
        folderName: 'Three',
      )!;
      expect(next[0]!.folderApps.map((item) => item.id), ['app:b', 'app:c']);
      expect(next[1]!.folderApps.map((item) => item.id), [
        'app:d',
        'app:e',
        'app:a',
      ]);
    });

    test('reordering keeps every app', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final next = HomeGridLayout.reorderFolder([folder], 0, 'app:a', 2)!;
      expect(next[0]!.folderApps.map((item) => item.id), [
        'app:b',
        'app:c',
        'app:a',
      ]);
    });

    test('folder contents count as grid applications', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      expect(
        HomeGridLayout.appsIn([HomeGridItem.clock(), folder, null, _item('c')])
            .map((item) => item.id),
        ['app:a', 'app:b', 'app:c'],
      );
    });
  });

  group('saved layouts', () {
    test('restore folders, drop missing apps and dissolve a lone app', () {
      final slots = HomeGridLayout.initialSlotsForApps(
        [_app('a'), _app('b'), _app('c'), _app('d')],
        const [],
        const [
          HomeLayoutSlot(id: 'widget:clock', colSpan: 2, rowSpan: 1),
          null,
          HomeLayoutSlot(
            id: 'folder:x',
            name: 'Tools',
            children: ['app:a', 'app:b'],
          ),
          HomeLayoutSlot(
            id: 'folder:y',
            name: 'Gone',
            children: ['app:c', 'app:uninstalled'],
          ),
        ],
      );
      expect(_ids(slots), ['widget:clock', null, 'folder:x', 'app:c', 'app:d']);
      expect(slots[2]!.folderName, 'Tools');
    });

    test('a refresh removes uninstalled apps from folders', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final slots = HomeGridLayout.refreshSlotsForApps(
        [folder],
        [_app('a'), _app('c')],
        const [],
      );
      expect(slots.single!.folderApps.map((item) => item.id), [
        'app:a',
        'app:c',
      ]);
    });
  });

  group('orientations', () {
    test('a reflow keeps the order and fits every item in its page', () {
      HomeGridLayout.columns = 6;
      final slots = [
        _item('a'),
        null,
        null,
        null,
        HomeGridItem.clock(colSpan: 4, rowSpan: 3),
        null,
        null,
        null,
        _item('b'),
      ];
      final next = HomeGridLayout.reflowSlots(slots, 18);
      // The widget covers cells 1-4, 7-10 and 13-16 of the first page.
      expect(_ids(next).take(6), [
        'app:a',
        'widget:clock',
        null,
        null,
        null,
        'app:b',
      ]);
      expect(next.skip(6), everyElement(isNull));
      expect([next[1]!.colSpan, next[1]!.rowSpan], [4, 3]);
    });

    test('a reflow shrinks a widget taller than the page', () {
      HomeGridLayout.columns = 6;
      final next = HomeGridLayout.reflowSlots([
        HomeGridItem.clock(colSpan: 2, rowSpan: 3),
      ], 12);
      expect([next[0]!.colSpan, next[0]!.rowSpan], [2, 2]);
    });

    test('each orientation saves its own layout', () async {
      final home = await Directory.systemTemp.createTemp('home-layout');
      addTearDown(() => home.delete(recursive: true));
      final repository = HomeLayoutRepository(
        paths: RuntimePaths(environment: {'HOME': home.path}),
      );
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      await repository.saveLayouts(
        HomeSavedLayouts(
          layouts: {
            HomeOrientation.portrait: [
              HomeLayoutSlot.of(HomeGridItem.clock(rowSpan: 2)),
              null,
              HomeLayoutSlot.of(folder),
            ],
            HomeOrientation.landscape: [HomeLayoutSlot.of(_item('c'))],
          },
        ),
      );

      final saved = await repository.readSavedLayouts();
      expect(saved.unassigned, isNull);
      final portrait = saved.layouts[HomeOrientation.portrait]!;
      expect([portrait[0]!.id, portrait[0]!.rowSpan], ['widget:clock', 2]);
      expect(portrait[1], isNull);
      expect(portrait[2]!.children, ['app:a', 'app:b']);
      expect(saved.layouts[HomeOrientation.landscape]!.single!.id, 'app:c');
    });

    test('a layout from before orientations belongs to none yet', () async {
      final home = await Directory.systemTemp.createTemp('home-layout');
      addTearDown(() => home.delete(recursive: true));
      final paths = RuntimePaths(environment: {'HOME': home.path});
      await (await paths.layoutFile()).writeAsString(
        '{"version": 3, "slots": ["app:a", null]}',
      );

      final saved = await HomeLayoutRepository(paths: paths).readSavedLayouts();
      expect(saved.layouts, isEmpty);
      expect([for (final slot in saved.unassigned!) slot?.id], ['app:a', null]);
    });
  });

  group('resizing', () {
    test('a widget grows leftward by moving its anchor', () {
      final slots = [null, HomeGridItem.clock()];
      final next = HomeGridLayout.resizeSlot(slots, 1, 0, 3, 1, pageSize)!;
      expect(next[1], isNull);
      expect(next[0]!.colSpan, 3);
    });

    test('a widget cannot grow over another item or off its page', () {
      final slots = [_item('a'), HomeGridItem.clock()];
      expect(
        HomeGridLayout.canResizeSlot(slots, 1, 0, 3, 1, pageSize),
        isFalse,
      );
      expect(HomeGridLayout.canResizeSlot(slots, 1, 1, 3, 1, pageSize), isTrue);
      expect(
        HomeGridLayout.canResizeSlot(slots, 1, 1, 3, 4, pageSize),
        isFalse,
      );
    });
  });
}
