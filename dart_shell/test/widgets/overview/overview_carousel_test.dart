import 'package:denial_dart_shell/src/features/mobile/mobile_primary_window_stage.dart';
import 'package:denial_dart_shell/src/widgets/window_content_rect.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_carousel.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_geometry.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_window_preview.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_layer.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_chrome.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_focus_overlay.dart';
import 'package:denial_dart_shell/src/widgets/retained_window_motion.dart';
import 'package:denial_dart_shell/src/widgets/window_hero.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tap selects the touched preview while coasting', (tester) async {
    const target = 2;
    final resampling = tester.binding.resamplingEnabled;
    tester.binding.resamplingEnabled = false;
    addTearDown(() => tester.binding.resamplingEnabled = resampling);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    final focused = <int>[];
    var closed = 0;
    await tester.pumpWidget(
      _overview(
        drag: drag,
        visible: true,
        onFocus: (window) => focused.add(window.objectId),
        onDismiss: () => closed++,
      ),
    );
    await tester.fling(_preview(3), const Offset(100, 0), 1000);
    await tester.pump(const Duration(milliseconds: 30));
    final pages = tester
        .widget<OverviewCarousel>(find.byType(OverviewCarousel))
        .pageController;
    expect(pages.position.isScrollingNotifier.value, isTrue);
    final rect = tester.getRect(_preview(target));
    final previewSize = tester
        .widget<OverviewWindowPreview>(_preview(target))
        .size;
    final visible = rect.intersect(const Rect.fromLTWH(0, 0, 400, 800));
    expect(visible.width, greaterThan(20));
    final pointer = await tester.startGesture(
      visible.center,
      kind: PointerDeviceKind.touch,
    );
    final stoppedAt = pages.offset;
    await tester.pump(const Duration(milliseconds: 50));
    expect(pages.offset, stoppedAt);
    await pointer.up();
    await tester.pump();
    expect(closed, 0);
    final overlay = tester.widget<OverviewFocusOverlay>(
      find.byType(OverviewFocusOverlay),
    );
    expect(overlay.window.objectId, target);
    expect(overlay.startRect, rect.topLeft & previewSize);
    await tester.pumpAndSettle();
    expect(focused, [target]);
    expect(closed, 0);
  });

  testWidgets('tapping outside the full-height carousel dismisses recents', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    var closed = 0;
    await tester.pumpWidget(
      _overview(drag: drag, visible: true, onDismiss: () => closed++),
    );
    await tester.tapAt(const Offset(200, 20));
    expect(closed, 1);
  });

  testWidgets('current app leads recents, older apps are on the left', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    await tester.pumpWidget(_overview(drag: drag, visible: true));
    final carousel = tester.widget<OverviewCarousel>(
      find.byType(OverviewCarousel),
    );
    expect(carousel.windows.map((window) => window.objectId), [3, 2, 1]);
    expect(tester.getCenter(_preview(3)).dx, 200);
    expect(tester.getCenter(_preview(2)).dx, lessThan(0));
    expect(
      find.descendant(
        of: find.byType(OverviewScrim),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
  });

  testWidgets('current app can be selected before the entry animation ends', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    var focused = 0;
    await tester.pumpWidget(_overview(drag: drag, visible: false));
    drag.value = -40;
    await tester.pump();
    drag.value = 0;
    await tester.pumpWidget(
      _overview(drag: drag, visible: true, onFocus: (_) => focused++),
    );
    final motion = tester.widget<RetainedWindowMotion>(
      find.byType(RetainedWindowMotion),
    );
    expect(motion.progress.value, lessThan(1));
    final hero = find.descendant(
      of: find.byType(RetainedWindowMotion),
      matching: find.byType(WindowSurface),
    );
    final pointer = await tester.startGesture(tester.getCenter(hero));
    await tester.pump(const Duration(milliseconds: 30));
    await pointer.up();
    await tester.pump();
    expect(find.byType(OverviewFocusOverlay), findsOneWidget);
    await tester.pumpAndSettle();
    expect(focused, 1);
  });

  testWidgets('older previews enter from the first part of the upward drag', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    await tester.pumpWidget(_overview(drag: drag, visible: false));

    drag.value = -12;
    await tester.pump();
    final preview = _preview(2);
    final element = preview.evaluate().single;
    final first = tester.getRect(preview);
    expect(first.right, greaterThan(0));
    expect(first.right, lessThan(10));
    final size = tester.widget<OverviewWindowPreview>(preview).size;
    final builds = <String>[];
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, _) =>
        builds.add(element.widget.runtimeType.toString());
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    var right = first.right;
    for (var travel = 16; travel <= 100; travel += 4) {
      drag.value = -travel.toDouble();
      await tester.pump();
      final rect = tester.getRect(preview);
      expect(rect.right, greaterThan(right));
      expect(rect.size, size);
      expect(preview.evaluate().single, same(element));
      right = rect.right;
    }
    expect(builds, isEmpty);
    debugOnRebuildDirtyWidget = previous;

    // Releasing into recents must continue from this position, including when
    // almost all of the gesture happened before the first settling frame.
    drag.value = 0;
    await tester.pumpWidget(_overview(drag: drag, visible: true));
    expect(tester.getRect(preview).right, closeTo(right, 0.01));
    await tester.pumpAndSettle();
    expect(tester.getRect(preview).right, greaterThan(right));
    expect(tester.getRect(preview).right, lessThan(60));
  });

  testWidgets('closing during focus cancels the stale activation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    var focused = 0;
    await tester.pumpWidget(
      _overview(drag: drag, visible: true, onFocus: (_) => focused++),
    );
    await tester.tap(_preview(3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpWidget(
      _overview(
        drag: drag,
        visible: false,
        foreground: false,
        onFocus: (_) => focused++,
      ),
    );
    await tester.pumpAndSettle();
    expect(focused, 0);
    expect(find.byType(OverviewFocusOverlay), findsNothing);
    expect(find.byType(OverviewCarousel), findsNothing);
  });

  testWidgets(
    'a horizontal swipe on the entering app immediately pages recents',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final drag = ValueNotifier(0.0);
      addTearDown(drag.dispose);
      await tester.pumpWidget(_overview(drag: drag, visible: false));
      drag.value = -40;
      await tester.pump();
      drag.value = 0;
      await tester.pumpWidget(_overview(drag: drag, visible: true));
      final hero = find.descendant(
        of: find.byType(RetainedWindowMotion),
        matching: find.byType(WindowSurface),
      );
      final before = tester.getTopLeft(hero);
      final pointer = await tester.startGesture(tester.getCenter(hero));
      await pointer.moveBy(const Offset(30, 0));
      await tester.pump();
      await pointer.moveBy(const Offset(70, 0));
      await tester.pump();
      final carousel = tester.widget<OverviewCarousel>(
        find.byType(OverviewCarousel),
      );
      expect(carousel.pageController.offset, greaterThan(0));
      expect(tester.getTopLeft(hero).dx, greaterThan(before.dx));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing slides every preview out and reopening preserves the current position',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final drag = ValueNotifier(0.0);
      addTearDown(drag.dispose);
      await tester.pumpWidget(_overview(drag: drag, visible: true));
      await tester.pumpWidget(
        _overview(drag: drag, visible: false, foreground: false),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final beforeReverse = tester.getTopLeft(_preview(3));
      await tester.pumpWidget(
        _overview(drag: drag, visible: true, foreground: false),
      );
      expect(tester.getTopLeft(_preview(3)), beforeReverse);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _overview(drag: drag, visible: false, foreground: false),
      );
      await tester.pump(const Duration(milliseconds: 260));
      expect(tester.getBottomRight(_preview(3)).dx, lessThan(0));
      await tester.pumpAndSettle();
      expect(find.byType(OverviewCarousel), findsNothing);
    },
  );

  testWidgets(
    'new drag takes over a cancelled gesture without snapping backwards',
    (tester) async {
      final drag = ValueNotifier(0.0);
      addTearDown(drag.dispose);
      await tester.pumpWidget(_overview(drag: drag, visible: false));
      drag.value = -90;
      await tester.pump();
      drag.value = 0;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final motion = tester.widget<RetainedWindowMotion>(
        find.byType(RetainedWindowMotion),
      );
      final progress = motion.progress.value;
      drag.value = -2;
      await tester.pump();
      expect(motion.progress.value, greaterThanOrEqualTo(progress));
      expect(motion.progress.value - progress, lessThan(0.03));
      drag.value = 0;
      await tester.pumpAndSettle();
      expect(find.byType(RetainedWindowMotion), findsNothing);
    },
  );

  testWidgets('focusing slides adjacent recents away at their original size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final drag = ValueNotifier(0.0);
    addTearDown(drag.dispose);
    final windows = [_window(1), _window(2), _window(3)];
    var focused = 0;
    await tester.pumpWidget(
      _harness(
        Stack(
          children: [
            OverviewLayer(
              windows: windows,
              foregroundWindow: windows.first,
              foregroundObjectId: 1,
              visible: true,
              swipeDy: drag,
              homeTransitionActive: false,
              onDismissOverview: () {},
              onDismissWindow: (_) {},
              onFocusWindow: (_) => focused++,
              onHomeSettled: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final adjacent = find.byWidgetPredicate(
      (w) => w is OverviewWindowPreview && w.window.objectId == 3,
    );
    final element = adjacent.evaluate().single;
    final rect = tester.getRect(adjacent);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is OverviewWindowPreview && w.window.objectId == 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(adjacent.evaluate().single, same(element));
    final movingRect = tester.getRect(adjacent);
    expect(movingRect.size, rect.size);
    expect(movingRect.top, rect.top);
    expect(movingRect.left, lessThan(rect.left));
    expect(focused, 0);
    double scrimOpacity() => tester
        .widgetList<FadeTransition>(
          find.descendant(
            of: find.byType(OverviewScrim),
            matching: find.byType(FadeTransition),
          ),
        )
        .fold(1.0, (value, fade) => value * fade.opacity.value);
    expect(scrimOpacity(), inExclusiveRange(0.0, 1.0));
    await tester.pump(const Duration(milliseconds: 190));
    expect(focused, 0);
    expect(scrimOpacity(), lessThan(0.01));
    await tester.pumpAndSettle();
    expect(focused, 1);
  });

  testWidgets(
    'live recents drag retains the hero and cancels back to full screen',
    (tester) async {
      final drag = ValueNotifier(0.0);
      addTearDown(drag.dispose);
      var overviewOwnsPresentation = false;
      final window = _window(1);
      await tester.pumpWidget(
        _harness(
          Stack(
            children: [
              OverviewLayer(
                windows: [window],
                foregroundWindow: window,
                foregroundObjectId: 1,
                visible: false,
                swipeDy: drag,
                homeTransitionActive: false,
                onPresentationChanged: (active) =>
                    overviewOwnsPresentation = active,
                onDismissOverview: () {},
                onDismissWindow: (_) {},
                onFocusWindow: (_) {},
                onHomeSettled: () {},
              ),
            ],
          ),
        ),
      );
      drag.value = -40;
      await tester.pump();
      expect(overviewOwnsPresentation, isTrue);
      final hero = find.descendant(
        of: find.byType(RetainedWindowMotion),
        matching: find.byType(WindowSurface),
      );
      final retained = tester.widget(hero);
      for (var i = 0; i < 15; i++) {
        drag.value -= 2;
        await tester.pump();
        expect(identical(tester.widget(hero), retained), isTrue);
      }
      drag.value = 0;
      await tester.pump(const Duration(milliseconds: 16));
      expect(hero, findsOneWidget);
      expect(overviewOwnsPresentation, isTrue);
      await tester.pumpAndSettle();
      expect(overviewOwnsPresentation, isFalse);
      expect(find.byType(RetainedWindowMotion), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'app switching only translates retained content and handles reversal',
    (tester) async {
      final drag = ValueNotifier(60.0);
      addTearDown(drag.dispose);
      await tester.pumpWidget(
        _harness(
          MobilePrimaryWindowStage(
            currentWindow: _window(1),
            switchTargetWindow: _window(2),
            switchDragX: drag,
            opacity: 1,
          ),
        ),
      );
      final current = find.byKey(const ValueKey<int>(1));
      final target = find.byKey(const ValueKey<int>(2));
      final currentElement = current.evaluate().single;
      final content = tester.widget<WindowContentRect>(current);
      final original = tester.getRect(current);
      drag.value = 130;
      await tester.pump();
      expect(identical(tester.widget(current), content), isTrue);
      expect(tester.getRect(current), original.shift(const Offset(70, 0)));
      expect(
        tester.getTopLeft(target).dx,
        lessThan(tester.getTopLeft(current).dx),
      );
      drag.value = -90;
      await tester.pump();
      expect(identical(tester.widget(current), content), isTrue);
      expect(tester.getRect(current), original.shift(const Offset(-150, 0)));
      expect(
        tester.getTopLeft(target).dx,
        greaterThan(tester.getTopLeft(current).dx),
      );
      for (final opacity in [0.0, 1.0]) {
        await tester.pumpWidget(
          _harness(
            MobilePrimaryWindowStage(
              currentWindow: _window(1),
              switchTargetWindow: _window(2),
              switchDragX: drag,
              opacity: opacity,
            ),
          ),
        );
        expect(current.evaluate().single, same(currentElement));
      }
    },
  );

  testWidgets(
    'paging retains previews, coasts across tasks and settles centered',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pages = PageController(
        viewportFraction: overviewPageViewportFractionFor(
          const Size(400, 800),
          EdgeInsets.zero,
        ),
      );
      final progress = AnimationController(vsync: tester, value: 1);
      addTearDown(pages.dispose);
      addTearDown(progress.dispose);
      Rect? focused;
      await tester.pumpWidget(
        _harness(
          OverviewCarousel(
            windows: [for (var id = 1; id <= 6; id++) _window(id)],
            progress: progress,
            pageController: pages,
            foregroundObjectId: null,
            onDismissWindow: (_) {},
            onFocusWindow: (_, rect) => focused = rect,
          ),
        ),
      );
      final first = find.byWidgetPredicate(
        (widget) =>
            widget is OverviewWindowPreview && widget.window.objectId == 1,
      );
      final originalWidget = tester.widget(first);
      final originalRect = tester.getRect(first);
      expect(
        originalRect.top,
        centerPreviewRectFor(
          const Size(400, 800),
          tester.widget<OverviewWindowPreview>(first).size,
        ).top,
      );

      pages.jumpTo(60);
      await tester.pump();
      expect(identical(tester.widget(first), originalWidget), isTrue);
      expect(tester.getRect(first).size, originalRect.size);
      for (final element in find.byType(OverviewWindowPreview).evaluate()) {
        final render = element.renderObject! as RenderBox;
        final transform = render.getTransformTo(null);
        expect(transform.entry(0, 0), 1);
        expect(transform.entry(1, 1), 1);
        element.visitAncestorElements((ancestor) {
          expect(ancestor.renderObject, isNot(isA<RenderOpacity>()));
          return true;
        });
      }
      await tester.tap(first);
      expect(focused!.topLeft, tester.getTopLeft(first));
      expect(focused!.size, tester.widget<OverviewWindowPreview>(first).size);

      progress.value = 0.7;
      await tester.pump();
      expect(identical(tester.widget(first), originalWidget), isTrue);
      expect(tester.getRect(first).size, originalRect.size);

      progress.value = 1;
      pages.jumpToPage(0);
      await tester.pumpAndSettle();
      (pages.position as ScrollPositionWithSingleContext).goBallistic(2000);
      await tester.pumpAndSettle();
      expect(pages.page, greaterThan(1));
      expect(pages.page, closeTo(pages.page!.roundToDouble(), 0.001));
    },
  );

  testWidgets('dismiss drag retains preview and commits exactly once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final pages = PageController(
      viewportFraction: overviewPageViewportFractionFor(
        const Size(400, 800),
        EdgeInsets.zero,
      ),
    );
    addTearDown(pages.dispose);
    final dismissed = <int>[];
    double? bottomAtDismiss;
    await tester.pumpWidget(
      _harness(
        OverviewCarousel(
          windows: [_window(1)],
          progress: const AlwaysStoppedAnimation(1),
          pageController: pages,
          foregroundObjectId: null,
          onDismissWindow: (window) {
            bottomAtDismiss = tester
                .getBottomRight(_preview(window.objectId))
                .dy;
            dismissed.add(window.objectId);
          },
          onFocusWindow: (_, _) {},
        ),
      ),
    );
    final preview = find.byType(OverviewWindowPreview);
    final originalWidget = tester.widget(preview);
    final originalRect = tester.getRect(preview);
    final gesture = await tester.startGesture(tester.getCenter(preview));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(Offset(0, -originalRect.bottom * 0.65));
    await tester.pump();
    expect(identical(tester.widget(preview), originalWidget), isTrue);
    expect(tester.getRect(preview).size, originalRect.size);
    expect(tester.getTopLeft(preview).dy, lessThan(originalRect.top));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(dismissed, [1]);
    await tester.pumpAndSettle();
    expect(dismissed, [1]);
    expect(bottomAtDismiss, lessThan(0));
  });

  test('portrait preview stride keeps the Android 16dp gap', () {
    for (final size in [
      const Size(400, 800),
      const Size(400, 1000),
      const Size(600, 900),
      const Size(320, 360),
    ]) {
      const padding = EdgeInsets.fromLTRB(12, 32, 12, 24);
      final card = cardSizeFor(
        constraints: BoxConstraints.tight(size),
        padding: padding,
        aspect: viewAspectFor(size),
      );
      final stride =
          overviewPageViewportFractionFor(size, padding) *
          overviewCarouselViewportWidthFor(size, card);
      expect(stride - card.width, closeTo(16, 0.001));
      expect(card.height, lessThanOrEqualTo(size.height - padding.vertical));
    }
  });

  testWidgets('short slow dismiss returns to its slot', (tester) async {
    final dismissed = <int>[];
    await _pumpCarousel(tester, onDismiss: (w) => dismissed.add(w.objectId));
    final before = tester.getRect(_preview(1));
    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(0, -210));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(dismissed, isEmpty);
    expect(tester.getRect(_preview(1)), before);
  });

  testWidgets('downward fling cancels even beyond the dismiss threshold', (
    tester,
  ) async {
    final dismissed = <int>[];
    await _pumpCarousel(tester, onDismiss: (w) => dismissed.add(w.objectId));
    final before = tester.getRect(_preview(1));
    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(
      const Offset(0, -30),
      timeStamp: const Duration(milliseconds: 100),
    );
    await gesture.moveBy(
      const Offset(0, -500),
      timeStamp: const Duration(milliseconds: 400),
    );
    await gesture.moveBy(
      const Offset(0, 30),
      timeStamp: const Duration(milliseconds: 410),
    );
    await gesture.moveBy(
      const Offset(0, 30),
      timeStamp: const Duration(milliseconds: 420),
    );
    await tester.pump();
    expect(tester.getTopLeft(_preview(1)).dy, lessThan(before.top - 400));
    await gesture.up(timeStamp: const Duration(milliseconds: 430));
    await tester.pumpAndSettle();
    expect(dismissed, isEmpty);
    expect(tester.getRect(_preview(1)), before);
  });

  testWidgets('a short upward fling dismisses and smoothly fills the gap', (
    tester,
  ) async {
    final dismissed = <int>[];
    final windows = ValueNotifier([_window(1), _window(2), _window(3)]);
    addTearDown(windows.dispose);
    final pages = await _pumpCarousel(
      tester,
      windows: windows,
      onDismiss: (w) => dismissed.add(w.objectId),
    );
    final neighborBefore = tester.getCenter(_preview(2));
    await tester.fling(_preview(1), const Offset(0, -100), 1600);
    for (var i = 0; dismissed.isEmpty && i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(dismissed, [1]);
    await tester.pump();
    final neighbor = tester.widget(_preview(2));
    await tester.pump(const Duration(milliseconds: 100));
    final during = tester.getCenter(_preview(2));
    expect(during.dx, lessThan(200));
    expect(during.dx, greaterThan(neighborBefore.dx));
    expect(tester.widget(_preview(2)), same(neighbor));
    await tester.pumpAndSettle();
    // The client deliberately has not acknowledged the close yet.
    expect(find.byType(OverviewWindowPreview), findsNWidgets(2));
    expect(_preview(1), findsNothing);
    expect(tester.getCenter(_preview(2)).dx, closeTo(200, 0.01));
    expect(pages.page, 0);
    // Unrelated snapshots during a delayed close must not resurrect its card.
    windows.value = [_window(1), _window(2), _window(3)];
    await tester.pumpAndSettle();
    expect(_preview(1), findsNothing);
    expect(tester.getCenter(_preview(2)).dx, closeTo(200, 0.01));
    windows.value = [_window(2), _window(3)];
    await tester.pumpAndSettle();
    expect(tester.getCenter(_preview(2)).dx, closeTo(200, 0.01));
  });

  testWidgets('holding a card offscreen does not commit before release', (
    tester,
  ) async {
    final dismissed = <int>[];
    await _pumpCarousel(tester, onDismiss: (w) => dismissed.add(w.objectId));
    final before = tester.getRect(_preview(1));
    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(0, -900));
    await tester.pump(const Duration(milliseconds: 300));
    expect(dismissed, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(dismissed, isEmpty);
    expect(tester.getRect(_preview(1)), before);
  });

  testWidgets('downward resistance reverses without sticking at its limit', (
    tester,
  ) async {
    await _pumpCarousel(tester);
    final before = tester.getRect(_preview(1));
    final gesture = await tester.startGesture(before.center);
    await gesture.moveBy(const Offset(0, 30));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    final displacement = tester.getTopLeft(_preview(1)).dy - before.top;
    expect(displacement, greaterThan(0));
    expect(displacement, lessThan(25));
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump();
    expect(tester.getRect(_preview(1)), before);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('removal before selected task preserves task identity', (
    tester,
  ) async {
    final windows = ValueNotifier([_window(1), _window(2), _window(3)]);
    addTearDown(windows.dispose);
    final pages = await _pumpCarousel(tester, windows: windows, initialPage: 1);
    final before = tester.getRect(_preview(2));
    windows.value = [_window(2), _window(3)];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getRect(_preview(2)), before);
    await tester.pumpAndSettle();
    expect(tester.getRect(_preview(2)), before);
    expect(pages.page, 0);
  });

  testWidgets('removing the last page settles on its preceding task', (
    tester,
  ) async {
    final windows = ValueNotifier([_window(1), _window(2), _window(3)]);
    addTearDown(windows.dispose);
    final pages = await _pumpCarousel(tester, windows: windows, initialPage: 2);
    windows.value = [_window(1), _window(2)];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getCenter(_preview(2)).dx, greaterThan(200));
    await tester.pumpAndSettle();
    expect(tester.getCenter(_preview(2)).dx, closeTo(200, 0.01));
    expect(pages.page, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('snapshots arriving during reflow settle on a surviving task', (
    tester,
  ) async {
    final windows = ValueNotifier([
      _window(1),
      _window(2),
      _window(3),
      _window(4),
    ]);
    addTearDown(windows.dispose);
    await _pumpCarousel(tester, windows: windows, initialPage: 1);
    windows.value = [_window(1), _window(3), _window(4)];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    windows.value = [_window(4), _window(5)];
    await tester.pumpAndSettle();
    expect(_preview(1), findsNothing);
    expect(_preview(2), findsNothing);
    expect(_preview(3), findsNothing);
    expect(tester.getCenter(_preview(4)).dx, closeTo(200, 0.01));
    expect(_preview(5), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<PageController> _pumpCarousel(
  WidgetTester tester, {
  ValueNotifier<List<DenialWindow>>? windows,
  ValueChanged<DenialWindow>? onDismiss,
  int initialPage = 0,
}) async {
  // Exercise release velocities using the supplied event timestamps. The
  // Denial fork enables resampling, whose frame clock rewrites synthetic
  // events sent in a tight test loop to the same timestamp.
  final resampling = tester.binding.resamplingEnabled;
  tester.binding.resamplingEnabled = false;
  addTearDown(() => tester.binding.resamplingEnabled = resampling);
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final pages = PageController(
    initialPage: initialPage,
    viewportFraction: overviewPageViewportFractionFor(
      const Size(400, 800),
      EdgeInsets.zero,
    ),
  );
  addTearDown(pages.dispose);
  final source = windows ?? ValueNotifier([_window(1), _window(2), _window(3)]);
  if (windows == null) addTearDown(source.dispose);
  await tester.pumpWidget(
    _harness(
      ValueListenableBuilder(
        valueListenable: source,
        builder: (context, value, _) => OverviewCarousel(
          windows: value,
          progress: const AlwaysStoppedAnimation(1),
          pageController: pages,
          foregroundObjectId: null,
          onDismissWindow: onDismiss ?? (_) {},
          onFocusWindow: (_, _) {},
        ),
      ),
    ),
  );
  return pages;
}

Finder _preview(int id) => find.byWidgetPredicate(
  (widget) => widget is OverviewWindowPreview && widget.window.objectId == id,
);

Widget _overview({
  required ValueNotifier<double> drag,
  required bool visible,
  bool foreground = true,
  ValueChanged<DenialWindow>? onFocus,
  VoidCallback? onDismiss,
}) => _harness(
  Stack(
    children: [
      OverviewLayer(
        windows: [_window(1), _window(2), _window(3)],
        foregroundWindow: foreground ? _window(3) : null,
        foregroundObjectId: foreground ? 3 : null,
        visible: visible,
        swipeDy: drag,
        homeTransitionActive: false,
        onDismissOverview: onDismiss ?? () {},
        onDismissWindow: (_) {},
        onFocusWindow: onFocus ?? (_) {},
        onHomeSettled: () {},
      ),
    ],
  ),
);

Widget _harness(Widget child) => ProviderScope(
  child: DenialLocalizationScope(
    locale: const Locale('en'),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: ShellTheme(
          data: const ShellThemeData(),
          child: Center(child: SizedBox(width: 400, height: 800, child: child)),
        ),
      ),
    ),
  ),
);

DenialWindow _window(int id) => DenialWindow(
  objectId: id,
  objectKind: 'xdg_toplevel',
  surfaceId: id,
  windowId: id,
  textureId: id,
  title: 'App $id',
  appId: 'test.$id',
  width: 400,
  height: 800,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 400,
  surfaceHeight: 800,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 400,
  textureSourceHeight: 800,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 400,
  geometryHeight: 800,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);
