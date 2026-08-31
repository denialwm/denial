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

void main() {
  test(
    'layout preview translates without resizing and then restores its target',
    () {
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
            contentRect: Rect.fromLTWH(400, 50, 300, 200),
            monitorId: 1,
            workspaceId: 1,
            phase: DenialWindowPlacementPhase.begin,
            change: DenialWindowPlacementChange.layoutPreview,
          ),
        ),
        isTrue,
      );
      final previewing = container
          .read(desktopWorkspaceProvider)
          .placements[7]!;
      expect(previewing.frame.topLeft, isNot(initial.frame.topLeft));
      expect(previewing.frame.size, initial.frame.size);
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
    },
  );
}
