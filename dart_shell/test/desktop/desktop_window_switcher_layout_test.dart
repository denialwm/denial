import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/state/desktop_window_switcher.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_switcher.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const stage = Rect.fromLTWH(0, 0, 1920, 1080);
  const firstNativeFrame = Rect.fromLTWH(80, 90, 800, 600);
  const secondNativeFrame = Rect.fromLTWH(920, 160, 720, 480);
  const firstDesktopFrame = Rect.fromLTWH(60, 700, 320, 240);
  const secondDesktopFrame = Rect.fromLTWH(400, 740, 300, 200);
  const first = DesktopWindowPlacement(
    objectId: 1,
    frame: firstNativeFrame,
    z: 2,
    monitorId: 1,
    minimized: true,
  );
  const second = DesktopWindowPlacement(
    objectId: 2,
    frame: secondNativeFrame,
    z: 1,
    monitorId: 1,
    minimized: true,
  );

  test('desktop-aware entry never passes through quick switch geometry', () {
    final controller = DesktopWindowSwitcherController();
    addTearDown(controller.dispose);
    final entering = controller.beginOrAdvance(
      objectIds: const <int>[1, 2],
      sourceObjectId: null,
      usesDesktopMotion: true,
    )!;

    final enteringFrame = DesktopWindowSwitcherLayout.visualFrame(
      placement: first,
      switcher: entering,
      stageBounds: stage,
      desktopWidgetFrame: firstDesktopFrame,
    );
    controller.expand(entering.sessionId);
    final expanded = controller.state!;
    final expandedFrame = DesktopWindowSwitcherLayout.visualFrame(
      placement: first,
      switcher: expanded,
      stageBounds: stage,
      desktopWidgetFrame: firstDesktopFrame,
    );

    expect(entering.expandedChromeVisible, isFalse);
    expect(DesktopWindowSwitcherLayout.motionDuration(entering),
        Motion.windowSwitcherExpand);
    expect(enteringFrame, expandedFrame);
    expect(enteringFrame, isNot(firstNativeFrame));
    expect(
      DesktopWindowSwitcherLayout.isVisible(
        placement: second,
        switcher: entering,
      ),
      isTrue,
    );
  });

  test('desktop-aware exit returns every minimized window to home', () {
    final controller = DesktopWindowSwitcherController();
    addTearDown(controller.dispose);
    final entering = controller.beginOrAdvance(
      objectIds: const <int>[1, 2],
      sourceObjectId: null,
      usesDesktopMotion: true,
    )!;
    controller.beginExpandedExit(entering.sessionId);
    final exiting = controller.state!;

    final unselectedFrame = DesktopWindowSwitcherLayout.visualFrame(
      placement: second,
      switcher: exiting,
      stageBounds: stage,
      desktopWidgetFrame: secondDesktopFrame,
    );
    final selectedFrame = DesktopWindowSwitcherLayout.visualFrame(
      placement: first.copyWith(minimized: false),
      switcher: exiting,
      stageBounds: stage,
      desktopWidgetFrame: firstDesktopFrame,
    );

    expect(exiting.expandedChromeVisible, isFalse);
    expect(DesktopWindowSwitcherLayout.motionDuration(exiting),
        Motion.windowSwitcherCollapse);
    expect(unselectedFrame, secondDesktopFrame);
    expect(selectedFrame, firstNativeFrame);
    expect(
      DesktopWindowSwitcherLayout.isVisible(
        placement: second,
        switcher: exiting,
      ),
      isTrue,
      reason: 'generic minimize opacity/scale must never run during exit',
    );
  });
}
