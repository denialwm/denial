import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const first = DesktopWindowPlacement(
    objectId: 1,
    frame: Rect.fromLTWH(10, 10, 300, 200),
    z: 1,
    monitorId: 11,
    workspaceId: 2,
  );
  const second = DesktopWindowPlacement(
    objectId: 2,
    frame: Rect.fromLTWH(400, 10, 300, 200),
    z: 2,
    monitorId: 22,
    workspaceId: 1,
  );
  const minimized = DesktopWindowPlacement(
    objectId: 3,
    frame: Rect.fromLTWH(30, 30, 300, 200),
    z: 3,
    monitorId: 11,
    workspaceId: -1,
    minimized: true,
  );

  test('active workspaces are independent per monitor', () {
    final state = DesktopWorkspaceState(
      placements: const <int, DesktopWindowPlacement>{
        1: first,
        2: second,
        3: minimized,
      },
      nextZ: 4,
      viewSize: const Size(1920, 1080),
      workspacesEnabled: true,
      workspaceCount: 4,
      activeWorkspaces: const <int, int>{11: 2, 22: 1},
    );

    expect(state.isPlacementOnActiveWorkspace(first), isTrue);
    expect(state.isPlacementOnActiveWorkspace(second), isTrue);
    expect(state.isPlacementOnActiveWorkspace(minimized), isTrue);
    expect(
      state.isPlacementOnActiveWorkspace(first.copyWith(workspaceId: 1)),
      isFalse,
    );
  });

  test(
    'only incoming and outgoing workspaces are presented in a transition',
    () {
      final state = DesktopWorkspaceState(
        placements: const <int, DesktopWindowPlacement>{1: first},
        nextZ: 2,
        viewSize: const Size(1920, 1080),
        workspacesEnabled: true,
        workspaceCount: 4,
        activeWorkspaces: const <int, int>{11: 3},
        workspaceTransitions: const <int, DesktopWorkspaceTransition>{
          11: DesktopWorkspaceTransition(
            monitorId: 11,
            fromWorkspace: 2,
            toWorkspace: 3,
            serial: 1,
          ),
        },
      );

      expect(state.isPlacementPresented(first), isTrue);
      expect(
        state.isPlacementPresented(first.copyWith(workspaceId: 3)),
        isTrue,
      );
      expect(
        state.isPlacementPresented(first.copyWith(workspaceId: 4)),
        isFalse,
      );
    },
  );
}
