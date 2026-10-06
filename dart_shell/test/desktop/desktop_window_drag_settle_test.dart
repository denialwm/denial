import 'package:denial_dart_shell/src/desktop/desktop_window_coordinator.dart';
import 'package:denial_dart_shell/src/desktop/retained_animated_positioned.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

DenialWindowPlacementEvent placementEvent({
  required int sequence,
  required Rect rect,
  required DenialWindowPlacementPhase phase,
}) {
  return DenialWindowPlacementEvent(
    sequence: sequence,
    windowId: 7,
    contentRect: rect,
    monitorId: 1,
    workspaceId: 1,
    phase: phase,
    change: DenialWindowPlacementChange.move,
  );
}

void main() {
  test('retains the exact live translation for the release handoff', () {
    final placements = DesktopLiveWindowPlacements();
    const initial = Rect.fromLTWH(10, 20, 300, 200);
    const released = Rect.fromLTWH(85, 65, 300, 200);
    placements.start(
      7,
      placementEvent(
        sequence: 1,
        rect: initial,
        phase: DenialWindowPlacementPhase.begin,
      ),
    );

    expect(
      placements.update(
        7,
        placementEvent(
          sequence: 2,
          rect: released,
          phase: DenialWindowPlacementPhase.update,
        ),
      ),
      DesktopLivePlacementUpdateResult.applied,
    );
    expect(placements.translationFor(7).value, const Offset(75, 45));

    placements.finish(7);

    expect(placements.translationFor(7).value, Offset.zero);
    expect(placements.settleTranslationFor(7), const Offset(75, 45));

    placements.start(
      7,
      placementEvent(
        sequence: 3,
        rect: initial,
        phase: DenialWindowPlacementPhase.begin,
      ),
    );
    expect(placements.settleTranslationFor(7), isNull);
    placements.dispose();
  });

  testWidgets('settles from a translated release rectangle into its tile', (
    tester,
  ) async {
    const childKey = ValueKey<String>('window');
    const initial = Rect.fromLTWH(10, 20, 100, 80);
    const released = Rect.fromLTWH(90, 70, 100, 80);
    const destination = Rect.fromLTWH(180, 30, 140, 120);

    Widget scene(Rect rect, {Rect? animationOrigin}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          height: 300,
          child: Stack(
            children: [
              RetainedAnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.linear,
                rect: rect,
                animationOrigin: animationOrigin,
                child: const ColoredBox(
                  key: childKey,
                  color: Color(0xff000000),
                ),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(initial));
    expect(tester.getRect(find.byKey(childKey)), initial);

    await tester.pumpWidget(scene(destination, animationOrigin: released));
    expect(tester.getRect(find.byKey(childKey)), released);

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.getRect(find.byKey(childKey)),
      Rect.lerp(released, destination, 0.5),
    );

    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byKey(childKey)), destination);
  });

  testWidgets('layout tile reflow has one restrained geometry bounce', (
    tester,
  ) async {
    const childKey = ValueKey<String>('reflowing-tile');
    const initial = Rect.fromLTWH(20, 30, 100, 80);
    const destination = Rect.fromLTWH(120, 30, 200, 80);

    Widget scene(Rect rect) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          height: 200,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              RetainedAnimatedPositioned(
                duration: Motion.layoutTileReflow,
                curve: Motion.layoutTileReflowCurve,
                rect: rect,
                child: const ColoredBox(
                  key: childKey,
                  color: Color(0xff000000),
                ),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(initial));
    await tester.pumpWidget(scene(destination));
    await tester.pump(const Duration(milliseconds: 150));

    final overshoot = tester.getRect(find.byKey(childKey));
    expect(overshoot.left, greaterThan(destination.left));
    expect(overshoot.left, lessThan(destination.left + 2));
    expect(overshoot.width, greaterThan(destination.width));
    expect(overshoot.width, lessThan(destination.width + 2));

    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getRect(find.byKey(childKey)), destination);
  });

  testWidgets('keeps a scene-space clip fixed while the window moves', (
    tester,
  ) async {
    const clipRect = Rect.fromLTWH(100, 0, 100, 100);
    var taps = 0;

    Widget scene(Rect rect) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 300,
          height: 100,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              RetainedAnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.linear,
                rect: rect,
                globalClipRect: clipRect,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps += 1,
                  child: const ColoredBox(color: Color(0xff000000)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(const Rect.fromLTWH(50, 0, 100, 100)));
    await tester.tapAt(const Offset(75, 50));
    expect(taps, 0);
    await tester.tapAt(const Offset(125, 50));
    expect(taps, 1);

    await tester.pumpWidget(scene(const Rect.fromLTWH(150, 0, 100, 100)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(90, 50));
    expect(taps, 1);
    await tester.tapAt(const Offset(125, 50));
    expect(taps, 2);
  });

  testWidgets('disabling the scene clip preserves an active pointer drag', (
    tester,
  ) async {
    const childKey = ValueKey<String>('drag-target');
    var clipped = true;
    var updates = 0;
    var ends = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 300,
          height: 200,
          child: StatefulBuilder(
            builder: (context, setState) => Stack(
              clipBehavior: Clip.none,
              children: [
                RetainedAnimatedPositioned(
                  duration: Duration.zero,
                  rect: const Rect.fromLTWH(50, 40, 160, 100),
                  globalClipRect: clipped
                      ? const Rect.fromLTWH(0, 0, 240, 200)
                      : null,
                  child: GestureDetector(
                    key: childKey,
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => setState(() => clipped = false),
                    onPanUpdate: (_) => updates += 1,
                    onPanEnd: (_) => ends += 1,
                    child: const ColoredBox(color: Color(0xff000000)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    addTearDown(mouse.removePointer);
    final center = tester.getCenter(find.byKey(childKey));
    await mouse.addPointer(location: center);
    await mouse.down(center);
    await mouse.moveBy(const Offset(20, 0));
    await tester.pump();

    expect(clipped, isFalse);
    final updatesAfterClipChanged = updates;

    await mouse.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(updates, greaterThan(updatesAfterClipChanged));

    await mouse.up();
    await tester.pump();
    expect(ends, 1);
  });
}
