import 'package:denial_dart_shell/src/desktop/desktop_window_coordinator.dart';
import 'package:denial_dart_shell/src/desktop/retained_animated_positioned.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
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
}
