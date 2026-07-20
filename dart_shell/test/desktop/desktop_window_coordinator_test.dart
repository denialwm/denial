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
    expect(
      backlog.takeReady((event) => true),
      <DenialWindowEvent>[unrelated],
    );
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

    expect(
      backlog.takeReady((event) => true),
      <DenialWindowEvent>[second, third],
    );
  });
}
