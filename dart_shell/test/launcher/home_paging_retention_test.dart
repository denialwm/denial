import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/home_surface.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/launcher/widgets/home_app_page.dart';
import 'package:denial_dart_shell/src/launcher/widgets/page_dots.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mobile_motion_harness.dart';

void main() {
  testWidgets('page changes update dots without rebuilding populated grids', (
    tester,
  ) async {
    const size = Size(600, 1000);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final grid = _PagingGrid();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [homeGridControllerProvider.overrideWith(() => grid)],
        child: mobileMotionHarness(const HomeSurface(), size: size),
      ),
    );
    await tester.pumpAndSettle();
    final pager = tester.widget<PageView>(find.byType(PageView));
    expect(
      tester.widget<PageDots>(find.byType(PageDots)).count,
      greaterThan(2),
    );
    final page = tester.widget<HomeAppPage>(find.byType(HomeAppPage).first);
    // This is the same callback fired at the midpoint of a real PageView
    // swipe. No scrolling or new-page construction masks the invalidation.
    pager.onPageChanged!(1);
    await tester.pump();
    expect(tester.widget<PageDots>(find.byType(PageDots)).active, 1);
    expect(tester.widget<PageView>(find.byType(PageView)), same(pager));
    expect(
      tester.widget<HomeAppPage>(find.byType(HomeAppPage).first),
      same(page),
    );
    pager.onPageChanged!(2);
    await tester.pump();
    expect(tester.widget<PageDots>(find.byType(PageDots)).active, 2);
    expect(
      tester.widget<HomeAppPage>(find.byType(HomeAppPage).first),
      same(page),
    );
    // Content edits still reach the grid, and shrinking the list clamps dots.
    grid.replaceSlots([_item(99)]);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<HomeAppPage>(find.byType(HomeAppPage).first)
          .slots
          .single
          ?.id,
      'app:99',
    );
    // Home always reserves at least two pages.
    expect(tester.widget<PageDots>(find.byType(PageDots)).active, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

HomeGridItem _item(int id) => HomeGridItem.app(
  DesktopApp(
    id: '$id',
    name: 'App $id',
    exec: 'unused',
    desktopPath: 'unused',
    categories: const [],
  ),
);

class _PagingGrid extends HomeGridController {
  @override
  Future<HomeGridState> build() async =>
      HomeGridState(slots: [for (var id = 0; id < 100; id++) _item(id)]);

  @override
  void setLauncherActive(bool active) {}

  void replaceSlots(List<HomeGridItem?> slots) {
    state = AsyncData(state.requireValue.copyWith(slots: slots));
  }
}
