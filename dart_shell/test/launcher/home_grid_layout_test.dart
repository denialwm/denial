import 'package:denial_dart_shell/src/launcher/controllers/home_grid_layout.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final originalColumns = HomeGridLayout.columns;
  tearDown(() => HomeGridLayout.columns = originalColumns);

  test('saved battery widget is removed without moving retained widgets', () {
    HomeGridLayout.columns = 4;
    final slots = HomeGridLayout.initialSlotsForApps([], [], [
      const HomeLayoutSlot(
        id: 'widget:battery-discharge',
        colSpan: 4,
        rowSpan: 2,
      ),
      for (var i = 1; i < 8; i++) null,
      const HomeLayoutSlot(id: 'widget:clock', colSpan: 3, rowSpan: 2),
    ]);
    expect(slots.whereType<HomeGridItem>().map((item) => item.id), [
      'widget:clock',
    ]);
    expect(slots[8]!.colSpan, 3);
    expect(slots[8]!.rowSpan, 2);
    expect(slots.take(8), everyElement(isNull));
  });

  test('bounded hit lookup matches occupied cells for every widget span', () {
    for (final columns in [4, 7, 14]) {
      HomeGridLayout.columns = columns;
      for (var width = 2; width <= 4; width++) {
        for (var height = 1; height <= 3; height++) {
          for (var anchor = 0; anchor < columns * 5; anchor++) {
            final item = HomeGridItem.clock(colSpan: width, rowSpan: height);
            if (!HomeGridLayout.itemFitsAtColumn(item, anchor)) continue;
            final cells = HomeGridLayout.cellsFor(anchor, item).toSet();
            final slots = List<HomeGridItem?>.filled(anchor + 1, null)
              ..[anchor] = item;
            for (var cell = -1; cell < columns * 8; cell++) {
              expect(
                HomeGridLayout.anchorForCell(cell, slots),
                cells.contains(cell) ? anchor : null,
              );
            }
            final pageSize = columns * 3;
            expect(
              HomeGridLayout.itemFitsInPage(anchor, item, pageSize),
              cells.every((cell) => cell ~/ pageSize == anchor ~/ pageSize),
            );
          }
        }
      }
    }
  });
}
