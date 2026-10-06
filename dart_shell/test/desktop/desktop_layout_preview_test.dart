import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const testWindow = DenialWindow(
  objectId: 7,
  objectKind: 'xdg',
  surfaceId: 17,
  windowId: 27,
  textureId: 37,
  title: 'Test',
  appId: 'test.app',
  width: 300,
  height: 200,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 300,
  surfaceHeight: 200,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 300,
  textureSourceHeight: 200,
  geometryX: 10,
  geometryY: 20,
  geometryWidth: 300,
  geometryHeight: 200,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);

const testWindowSibling = DenialWindow(
  objectId: 8,
  objectKind: 'xdg',
  surfaceId: 18,
  windowId: 28,
  textureId: 38,
  title: 'Sibling',
  appId: 'test.sibling',
  width: 300,
  height: 200,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 300,
  surfaceHeight: 200,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 300,
  textureSourceHeight: 200,
  geometryX: 320,
  geometryY: 20,
  geometryWidth: 300,
  geometryHeight: 200,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);

const testWindowOnSecondWorkspace = DenialWindow(
  objectId: 7,
  objectKind: 'xdg',
  surfaceId: 17,
  windowId: 27,
  textureId: 37,
  title: 'Test',
  appId: 'test.app',
  width: 300,
  height: 200,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 300,
  surfaceHeight: 200,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 300,
  textureSourceHeight: 200,
  geometryX: 10,
  geometryY: 20,
  geometryWidth: 300,
  geometryHeight: 200,
  monitorId: 2,
  workspaceId: 2,
  transform: 0,
  scale120: 120,
);

const testWindowBeforeScaleChange = DenialWindow(
  objectId: 8,
  objectKind: 'xdg',
  surfaceId: 18,
  windowId: 28,
  textureId: 38,
  title: 'Scaled output window',
  appId: 'test.scaling',
  width: 600,
  height: 200,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 600,
  surfaceHeight: 200,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 600,
  textureSourceHeight: 200,
  geometryX: 3300,
  geometryY: 20,
  geometryWidth: 600,
  geometryHeight: 200,
  monitorId: 2,
  transform: 0,
  scale120: 120,
);

const testWindowAfterScaleChange = DenialWindow(
  objectId: 8,
  objectKind: 'xdg',
  surfaceId: 18,
  windowId: 28,
  textureId: 38,
  title: 'Scaled output window',
  appId: 'test.scaling',
  width: 480,
  height: 200,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 480,
  surfaceHeight: 200,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 480,
  textureSourceHeight: 200,
  geometryX: 1800,
  geometryY: 20,
  geometryWidth: 480,
  geometryHeight: 200,
  monitorId: 2,
  transform: 0,
  scale120: 150,
);

void main() {
  test('native retiling replaces the interim metrics-change clamp', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);

    workspace.syncWindows(
      const [testWindowBeforeScaleChange],
      const Size(4000, 2560),
      1,
      snapshotSequence: 1,
    );
    workspace.syncWindows(
      const [testWindowBeforeScaleChange],
      const Size(3000, 2560),
      1.25,
      snapshotSequence: 1,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[8]!.contentRect,
      isNot(testWindowBeforeScaleChange.geometry),
    );

    workspace.syncWindows(
      const [testWindowAfterScaleChange],
      const Size(3000, 2560),
      1.25,
      snapshotSequence: 2,
    );

    expect(
      container.read(desktopWorkspaceProvider).placements[8]!.contentRect,
      testWindowAfterScaleChange.geometry,
    );
  });

  test('layout preview moves and resizes before restoring its target', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    workspace.syncWindows(
      const [testWindow],
      const Size(1200, 800),
      1,
      snapshotSequence: 1,
    );
    final initial = container.read(desktopWorkspaceProvider).placements[7]!;

    expect(
      workspace.applyNativePlacement(
        7,
        const DenialWindowPlacementEvent(
          sequence: 2,
          windowId: 27,
          contentRect: Rect.fromLTWH(400, 50, 180, 320),
          monitorId: 1,
          workspaceId: 1,
          phase: DenialWindowPlacementPhase.begin,
          change: DenialWindowPlacementChange.layoutPreview,
        ),
      ),
      isTrue,
    );
    final previewing = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(previewing.frame.topLeft, isNot(initial.frame.topLeft));
    expect(previewing.frame.size, isNot(initial.frame.size));
    expect(previewing.layoutPreviewing, isTrue);
    expect(previewing.dragging, isFalse);

    workspace.applyNativePlacement(
      7,
      const DenialWindowPlacementEvent(
        sequence: 3,
        windowId: 27,
        contentRect: Rect.fromLTWH(10, 20, 300, 200),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.end,
        change: DenialWindowPlacementChange.layoutPreview,
      ),
    );
    final restored = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(restored.frame, initial.frame);
    expect(restored.layoutPreviewing, isFalse);
    expect(restored.dragging, isFalse);
  });

  test('sibling layout previews settle independently', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    workspace.syncWindows(
      const [testWindow, testWindowSibling],
      const Size(1200, 800),
      1,
      snapshotSequence: 1,
    );
    final initialFirst = container
        .read(desktopWorkspaceProvider)
        .placements[7]!;
    final initialSecond = container
        .read(desktopWorkspaceProvider)
        .placements[8]!;

    for (final event in const [
      DenialWindowPlacementEvent(
        sequence: 2,
        windowId: 27,
        contentRect: Rect.fromLTWH(10, 20, 300, 90),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.begin,
        change: DenialWindowPlacementChange.layoutPreview,
      ),
      DenialWindowPlacementEvent(
        sequence: 2,
        windowId: 28,
        contentRect: Rect.fromLTWH(320, 120, 300, 100),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.begin,
        change: DenialWindowPlacementChange.layoutPreview,
      ),
    ]) {
      expect(
        workspace.applyNativePlacement(event.windowId == 27 ? 7 : 8, event),
        isTrue,
      );
    }
    expect(
      container.read(desktopWorkspaceProvider).placements[7]!.layoutPreviewing,
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[8]!.layoutPreviewing,
      isTrue,
    );

    workspace.applyNativePlacement(
      7,
      DenialWindowPlacementEvent(
        sequence: 3,
        windowId: 27,
        contentRect: initialFirst.contentRect,
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.end,
        change: DenialWindowPlacementChange.layoutPreview,
      ),
    );
    final partiallySettled = container.read(desktopWorkspaceProvider);
    expect(partiallySettled.placements[7]!.layoutPreviewing, isFalse);
    expect(partiallySettled.placements[8]!.layoutPreviewing, isTrue);

    workspace.applyNativePlacement(
      8,
      DenialWindowPlacementEvent(
        sequence: 3,
        windowId: 28,
        contentRect: initialSecond.contentRect,
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.end,
        change: DenialWindowPlacementChange.layoutPreview,
      ),
    );
    final settled = container.read(desktopWorkspaceProvider);
    expect(settled.placements[7]!.frame, initialFirst.frame);
    expect(settled.placements[8]!.frame, initialSecond.frame);
    expect(settled.placements[8]!.layoutPreviewing, isFalse);
  });

  test('overtaking metadata cannot discard geometry or revert ownership', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    workspace.syncWindows(
      const [testWindow],
      const Size(1200, 800),
      1,
      snapshotSequence: 1,
    );

    expect(
      workspace.applyNativePlacement(
        7,
        const DenialWindowPlacementEvent(
          sequence: 2,
          windowId: 27,
          contentRect: Rect.fromLTWH(110, 20, 300, 200),
          monitorId: 1,
          workspaceId: 1,
          phase: DenialWindowPlacementPhase.update,
          change: DenialWindowPlacementChange.move,
        ),
      ),
      isTrue,
    );

    // Flutter may receive a newer scene snapshot before the batched next
    // placement is reduced. Because live movement owns geometry, this
    // snapshot must not make that ordered placement stale.
    workspace.syncWindows(
      const [testWindowOnSecondWorkspace],
      const Size(1200, 800),
      1,
      snapshotSequence: 4,
    );
    expect(
      workspace.applyNativePlacement(
        7,
        const DenialWindowPlacementEvent(
          sequence: 3,
          windowId: 27,
          contentRect: Rect.fromLTWH(210, 20, 300, 200),
          monitorId: 1,
          workspaceId: 1,
          phase: DenialWindowPlacementPhase.update,
          change: DenialWindowPlacementChange.move,
        ),
      ),
      isTrue,
    );
    final placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.contentRect, const Rect.fromLTWH(210, 20, 300, 200));
    expect(placement.monitorId, 2);
    expect(placement.workspaceId, 2);
  });
}
