import 'package:denial_dart_shell/src/widgets/shade/notification_shade_list.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'panel compression preserves card layout and horizontal entrance',
    (tester) async {
      final progress = AnimationController(vsync: tester, value: 1);
      final entrance = AnimationController(vsync: tester, value: 1);
      addTearDown(progress.dispose);
      addTearDown(entrance.dispose);
      var taps = 0;
      await tester.pumpWidget(_list(progress, entrance, () => taps++));
      final first = find.byKey(const ValueKey('row-0'));
      final second = find.byKey(const ValueKey('row-1'));
      final third = find.byKey(const ValueKey('row-2'));
      final originalSize = tester.getSize(first);
      final gap = tester.getTopLeft(second).dy - tester.getTopLeft(first).dy;

      entrance.value = 0.2;
      await tester.pump();
      final firstX = tester.getTopLeft(first).dx;
      expect(firstX, lessThan(0));
      expect(tester.getTopLeft(second).dx, lessThan(firstX));
      progress.value = 0.5;
      await tester.pump();
      expect(tester.getTopLeft(first).dx, firstX);
      expect(
        tester.getTopLeft(second).dy - tester.getTopLeft(first).dy,
        gap * 0.5,
      );
      expect(tester.getSize(first), originalSize);
      entrance.value = 0.5;
      await tester.pump();
      expect(tester.getTopLeft(first).dx, greaterThan(firstX));
      expect(
        tester.getTopLeft(second).dy - tester.getTopLeft(first).dy,
        gap * 0.5,
      );

      entrance.value = 1;
      await tester.pump();
      // This point lies below the former viewport-height × progress clip.
      // Full-sized overlapping cards must still receive input there.
      await tester.tapAt(const Offset(50, 200));
      expect(taps, 1);
      progress.value = 1;
      await tester.pump();
      await tester.tap(third);
      expect(taps, 2, reason: 'Hit testing must follow the painted card');
      progress.value = 0.001;
      await tester.pump();
      expect(tester.getBottomLeft(first).dy, lessThan(1));
      expect(tester.getSize(first), originalSize);
      progress.value = 0;
      await tester.pump();
      await tester.tapAt(const Offset(50, 20));
      expect(taps, 2, reason: 'Fully closed cards must not intercept input');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('overlap excludes covered input but preserves rounded corners', (
    tester,
  ) async {
    final progress = AnimationController(vsync: tester, value: 0.5);
    addTearDown(progress.dispose);
    var taps = 0;
    Widget view(Offset upperOffset) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          height: 400,
          child: Padding(
            padding: const EdgeInsets.only(top: 100),
            child: CustomScrollView(
              clipBehavior: Clip.none,
              slivers: [
                NotificationShadeList(
                  progress: progress,
                  entrance: const AlwaysStoppedAnimation(1),
                  delegate: SliverChildListDelegate([
                    IgnorePointer(
                      child: Transform.translate(
                        offset: upperOffset,
                        child: const NotificationShadeSurface(
                          borderRadius: BorderRadius.all(Radius.circular(28)),
                          child: SizedBox(height: 100),
                        ),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => taps++,
                      child: const NotificationShadeSurface(
                        borderRadius: BorderRadius.all(Radius.circular(28)),
                        child: SizedBox(height: 100),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(view(Offset.zero));
    await tester.tapAt(const Offset(160, 175));
    expect(taps, 1, reason: 'Uncovered lower-card content remains interactive');
    await tester.tapAt(const Offset(160, 125));
    expect(
      taps,
      1,
      reason: 'A covered card must not receive taps through the top card',
    );
    await tester.tapAt(const Offset(2, 148));
    expect(taps, 2, reason: 'A rounded corner is not a rectangular occluder');
    await tester.pumpWidget(view(const Offset(150, 0)));
    NotificationShadeList.invalidateOcclusion(
      tester.element(find.byType(NotificationShadeSurface).first),
    );
    await tester.pump();
    await tester.tapAt(const Offset(20, 125));
    expect(
      taps,
      3,
      reason: 'Sideways motion exposes the actual underlying card',
    );
    await tester.tapAt(const Offset(220, 125));
    expect(taps, 3);
    progress.value = 1;
    await tester.pump();
    await tester.tapAt(const Offset(220, 275));
    expect(
      taps,
      4,
      reason: 'Reopening removes the overlap without changing size',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'scrolling and differently sized rows retain geometry across reversal',
    (tester) async {
      final progress = AnimationController(vsync: tester, value: 1);
      final entrance = AnimationController(vsync: tester, value: 1);
      addTearDown(progress.dispose);
      addTearDown(entrance.dispose);
      await tester.pumpWidget(_list(progress, entrance, () {}));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      final originalOffset = scroll.pixels;
      final originalExtent = scroll.maxScrollExtent;
      final row = find.byKey(const ValueKey('row-3'));
      final originalPosition = tester.getTopLeft(row);
      final originalSize = tester.getSize(row);
      for (final value in [0.8, 0.3, 0.6, 1.0]) {
        progress.value = value;
        await tester.pump();
        expect(scroll.pixels, originalOffset);
        expect(scroll.maxScrollExtent, originalExtent);
        expect(tester.getSize(row), originalSize);
      }
      expect(tester.getTopLeft(row), originalPosition);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Widget _list(
  Animation<double> progress,
  Animation<double> entrance,
  VoidCallback onTap,
) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 320,
      height: 400,
      child: CustomScrollView(
        slivers: [
          NotificationShadeList(
            progress: progress,
            entrance: entrance,
            delegate: SliverChildBuilderDelegate(
              (_, index) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: SizedBox(
                  key: ValueKey('row-$index'),
                  height: index.isEven ? 90 : 120,
                  child: Text('Notification $index'),
                ),
              ),
              childCount: 15,
            ),
          ),
        ],
      ),
    ),
  ),
);
