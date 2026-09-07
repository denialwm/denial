import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/models/home_clock_info.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/launcher/widgets/home_app_page.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('holding the enlarged resize handle keeps its drag and page', (
    tester,
  ) async {
    final resampling = tester.binding.resamplingEnabled;
    tester.binding.resamplingEnabled = false;
    addTearDown(() => tester.binding.resamplingEnabled = resampling);
    final pages = PageController();
    addTearDown(pages.dispose);
    Offset? start;
    Offset? latest;
    var ended = 0;
    var moveModeEvents = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeClockProvider.overrideWithValue(
            HomeClockInfo(
              now: DateTime(2026, 9, 5, 12),
              locale: 'en',
              power: HomePowerStatus.unknown,
            ),
          ),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ShellTheme(
              data: const ShellThemeData(),
              child: DefaultTextStyle(
                style: const TextStyle(fontSize: 14),
                child: PageView(
                  controller: pages,
                  children: [
                    HomeAppPage(
                      slots: [HomeGridItem.clock()],
                      startIndex: 0,
                      pageSize: 16,
                      columns: 4,
                      gap: 12,
                      tileWidth: 80,
                      tileHeight: 120,
                      draggingSourceIndex: null,
                      resizeModeIndex: 0,
                      onLaunch: (_, _) {},
                      onDragStart: (_, _, _, _, _) => moveModeEvents++,
                      onDragEnd: (_) => moveModeEvents++,
                      onDragUpdate: (_) => moveModeEvents++,
                      onResizeModeStart: (_, _, _, _) => moveModeEvents++,
                      onResizeModeMove: (_, _, _, _, _) => moveModeEvents++,
                      onResizeModeEnd: () => moveModeEvents++,
                      onResizeStart: (_, _, _, details) =>
                          start = details.globalPosition,
                      onResizeUpdate: (details) =>
                          latest = details.globalPosition,
                      onResizeEnd: () => ended++,
                    ),
                    const SizedBox.expand(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final handle = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics && widget.properties.label == 'Resize widget',
    );
    // Start outside the visible grip, inside its expanded touch target.
    final origin = tester.getTopLeft(handle) + const Offset(4, 4);
    final pointer = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 700));
    await pointer.moveBy(const Offset(-70, 0));
    await tester.pump();
    expect(start, origin);
    expect(latest, origin + const Offset(-70, 0));
    expect(pages.offset, 0);
    expect(moveModeEvents, 0);
    await pointer.moveBy(const Offset(35, 0));
    await tester.pump();
    expect(latest, origin + const Offset(-35, 0));
    await pointer.cancel();
    await tester.pump();
    expect(ended, 1);
    expect(tester.takeException(), isNull);
  });
}
