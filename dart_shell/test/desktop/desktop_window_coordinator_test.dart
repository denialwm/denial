import 'package:denial_dart_shell/src/desktop/desktop_window_coordinator.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup placement and state wait together in FIFO order', () {
    final backlog = DesktopWindowEventBacklog();
    const placement = DenialWindowPlacementEvent(
      sequence: 10,
      windowId: 11,
      contentRect: Rect.fromLTWH(100, 120, 800, 600),
      monitorId: 1,
      workspaceId: 1,
      phase: DenialWindowPlacementPhase.end,
      change: DenialWindowPlacementChange.resize,
    );
    const maximize = DenialWindowActionEvent(
      windowId: 11,
      action: DenialWindowAction.maximize,
    );
    const unrelated = DenialWindowActionEvent(
      windowId: 22,
      action: DenialWindowAction.minimize,
    );
    backlog
      ..add(placement)
      ..add(maximize)
      ..add(unrelated);

    expect(backlog.takeReady((event) => false), isEmpty);
    expect(backlog.length, 3);
    expect(
      backlog.takeReady((event) => event.windowId == 11),
      <DenialWindowEvent>[placement, maximize],
    );
    expect(backlog.length, 1);
    expect(backlog.takeReady((event) => true), <DenialWindowEvent>[unrelated]);
  });

  test('startup event backlog drops the oldest event at its hard bound', () {
    final backlog = DesktopWindowEventBacklog(capacity: 2);
    const first = DenialWindowActionEvent(
      windowId: 1,
      action: DenialWindowAction.maximize,
    );
    const second = DenialWindowActionEvent(
      windowId: 2,
      action: DenialWindowAction.restore,
    );
    const third = DenialWindowActionEvent(
      windowId: 3,
      action: DenialWindowAction.toggleFullscreen,
    );
    backlog
      ..add(first)
      ..add(second)
      ..add(third);

    expect(backlog.takeReady((event) => true), <DenialWindowEvent>[
      second,
      third,
    ]);
  });

  test('placement frame batch keeps only the newest update per window', () {
    final batch = DesktopWindowPlacementFrameBatch();
    const firstWindowOld = DenialWindowPlacementEvent(
      sequence: 10,
      windowId: 11,
      contentRect: Rect.fromLTWH(100, 120, 800, 600),
      monitorId: 1,
      workspaceId: 1,
      phase: DenialWindowPlacementPhase.update,
      change: DenialWindowPlacementChange.move,
    );
    const secondWindow = DenialWindowPlacementEvent(
      sequence: 12,
      windowId: 22,
      contentRect: Rect.fromLTWH(500, 400, 640, 480),
      monitorId: 1,
      workspaceId: 1,
      phase: DenialWindowPlacementPhase.update,
      change: DenialWindowPlacementChange.move,
    );
    const firstWindowNew = DenialWindowPlacementEvent(
      sequence: 13,
      windowId: 11,
      contentRect: Rect.fromLTWH(140, 160, 800, 600),
      monitorId: 1,
      workspaceId: 1,
      phase: DenialWindowPlacementPhase.update,
      change: DenialWindowPlacementChange.move,
    );

    batch
      ..add(firstWindowOld)
      ..add(secondWindow)
      ..add(firstWindowNew)
      ..add(firstWindowOld);

    expect(batch.length, 2);
    expect(batch.takeAll(), <DenialWindowPlacementEvent>[
      secondWindow,
      firstWindowNew,
    ]);
    expect(batch.length, 0);
  });

  test('placement frame batch can discard an update superseded by end', () {
    final batch = DesktopWindowPlacementFrameBatch();
    const update = DenialWindowPlacementEvent(
      sequence: 10,
      windowId: 11,
      contentRect: Rect.fromLTWH(100, 120, 800, 600),
      monitorId: 1,
      workspaceId: 1,
      phase: DenialWindowPlacementPhase.update,
      change: DenialWindowPlacementChange.move,
    );
    batch.add(update);

    expect(batch.remove(update.windowId), update);
    expect(batch.takeAll(), isEmpty);
  });

  test('live move publishes only retained translation until finish', () {
    final placements = DesktopLiveWindowPlacements();
    addTearDown(placements.dispose);
    final translation = placements.translationFor(1);
    final sameTranslation = placements.translationFor(1);
    final begin = _placement(
      sequence: 20,
      phase: DenialWindowPlacementPhase.begin,
      contentRect: const Rect.fromLTWH(100, 120, 800, 600),
    );
    final update = _placement(
      sequence: 21,
      phase: DenialWindowPlacementPhase.update,
      contentRect: const Rect.fromLTWH(145, 170, 800, 600),
    );

    expect(sameTranslation, same(translation));
    placements.start(1, begin);
    expect(
      placements.update(1, update),
      DesktopLivePlacementUpdateResult.applied,
    );
    expect(translation.value, const Offset(45, 50));

    expect(placements.finish(1), update);
    expect(translation.value, Offset.zero);
  });

  test('live move rejects stale and layout-changing updates', () {
    final placements = DesktopLiveWindowPlacements();
    addTearDown(placements.dispose);
    final translation = placements.translationFor(1);
    placements.start(
      1,
      _placement(
        sequence: 20,
        phase: DenialWindowPlacementPhase.begin,
        contentRect: const Rect.fromLTWH(100, 120, 800, 600),
      ),
    );
    final newest = _placement(
      sequence: 23,
      phase: DenialWindowPlacementPhase.update,
      contentRect: const Rect.fromLTWH(160, 180, 800, 600),
    );
    expect(
      placements.update(1, newest),
      DesktopLivePlacementUpdateResult.applied,
    );

    expect(
      placements.update(
        1,
        _placement(
          sequence: 22,
          phase: DenialWindowPlacementPhase.update,
          contentRect: const Rect.fromLTWH(130, 150, 800, 600),
        ),
      ),
      DesktopLivePlacementUpdateResult.stale,
    );
    expect(translation.value, const Offset(60, 60));

    expect(
      placements.update(
        1,
        _placement(
          sequence: 24,
          phase: DenialWindowPlacementPhase.update,
          change: DenialWindowPlacementChange.resize,
          contentRect: const Rect.fromLTWH(160, 180, 840, 620),
        ),
      ),
      DesktopLivePlacementUpdateResult.incompatible,
    );
    expect(translation.value, const Offset(60, 60));
    expect(placements.isStaleBoundary(1, 23), isTrue);
    expect(placements.isStaleBoundary(1, 24), isFalse);
  });
}

DenialWindowPlacementEvent _placement({
  required int sequence,
  required DenialWindowPlacementPhase phase,
  required Rect contentRect,
  DenialWindowPlacementChange change = DenialWindowPlacementChange.move,
}) {
  return DenialWindowPlacementEvent(
    sequence: sequence,
    windowId: 11,
    contentRect: contentRect,
    monitorId: 1,
    workspaceId: 1,
    phase: phase,
    change: change,
  );
}
