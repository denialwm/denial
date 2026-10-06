import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DenialWindow nativeWindow({
  required String objectKind,
  required Rect geometry,
  required bool fullscreen,
  int objectId = 7,
  int? transientParentObjectId,
  bool maximized = false,
  DenialWindowContentKind contentKind = DenialWindowContentKind.surfaceTree,
}) {
  return DenialWindow(
    objectId: objectId,
    objectKind: objectKind,
    surfaceId: objectId + 10,
    windowId: objectId + 20,
    textureId: objectId + 30,
    title: 'Protocol client',
    appId: 'protocol.client',
    width: geometry.width.round(),
    height: geometry.height.round(),
    surfaceX: 0,
    surfaceY: 0,
    surfaceWidth: geometry.width,
    surfaceHeight: geometry.height,
    textureSourceX: 0,
    textureSourceY: 0,
    textureSourceWidth: geometry.width,
    textureSourceHeight: geometry.height,
    geometryX: geometry.left,
    geometryY: geometry.top,
    geometryWidth: geometry.width,
    geometryHeight: geometry.height,
    monitorId: 1,
    transientParentObjectId: transientParentObjectId,
    maximized: maximized,
    fullscreen: fullscreen,
    transform: 0,
    scale120: 120,
    contentKind: contentKind,
  );
}

void main() {
  for (final objectKind in <String>['xdg', 'x11']) {
    test(
      '$objectKind startup-fullscreen action cannot block a later layout split',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final workspace = container.read(desktopWorkspaceProvider.notifier);
        const viewSize = Size(1920, 1080);
        const fullscreenGeometry = Rect.fromLTWH(0, 0, 1920, 1080);
        final fullscreen = nativeWindow(
          objectKind: objectKind,
          geometry: fullscreenGeometry,
          fullscreen: true,
        );

        workspace.syncWindows(
          <DenialWindow>[fullscreen],
          viewSize,
          1,
          snapshotSequence: 10,
        );

        expect(
          workspace.applyFlutterOwnedWindowAction(
            fullscreen,
            DenialWindowAction.restore,
            maximizeBounds: fullscreenGeometry,
            fullscreenBounds: fullscreenGeometry,
          ),
          isFalse,
        );
        expect(
          container.read(desktopWorkspaceProvider).placements[7]!.frame,
          fullscreenGeometry,
        );

        const tileGeometry = Rect.fromLTWH(10, 30, 900, 1000);
        workspace.syncWindows(
          <DenialWindow>[
            nativeWindow(
              objectKind: objectKind,
              geometry: tileGeometry,
              fullscreen: false,
            ),
          ],
          viewSize,
          1,
          snapshotSequence: 11,
        );

        final placement = container
            .read(desktopWorkspaceProvider)
            .placements[7]!;
        expect(placement.fullscreen, isFalse);
        expect(placement.contentRect, tileGeometry);
      },
    );
  }

  test('popup surfaces never enter the desktop placement stack', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);

    workspace.syncWindows(
      <DenialWindow>[
        nativeWindow(
          objectKind: 'x11',
          geometry: const Rect.fromLTWH(240, 180, 320, 72),
          fullscreen: false,
          contentKind: DenialWindowContentKind.popupSurface,
        ),
      ],
      const Size(1920, 1080),
      1,
      snapshotSequence: 12,
    );

    expect(container.read(desktopWorkspaceProvider).placements, isEmpty);
  });

  test('activating a transient parent keeps its dialog above the family', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const viewSize = Size(1920, 1080);

    final parent = nativeWindow(
      objectKind: 'xdg',
      geometry: const Rect.fromLTWH(100, 80, 900, 700),
      fullscreen: false,
    );
    final dialog = nativeWindow(
      objectId: 8,
      objectKind: 'xdg',
      geometry: const Rect.fromLTWH(350, 260, 400, 260),
      fullscreen: false,
      transientParentObjectId: parent.objectId,
    );
    final unrelated = nativeWindow(
      objectId: 9,
      objectKind: 'xdg',
      geometry: const Rect.fromLTWH(1100, 100, 600, 600),
      fullscreen: false,
    );

    workspace.syncWindows(
      <DenialWindow>[parent, dialog, unrelated],
      viewSize,
      1,
      snapshotSequence: 13,
    );
    workspace.activate(parent.objectId);

    final placements = container.read(desktopWorkspaceProvider).placements;
    expect(
      placements[parent.objectId]!.z,
      greaterThan(placements[unrelated.objectId]!.z),
    );
    expect(
      placements[dialog.objectId]!.z,
      greaterThan(placements[parent.objectId]!.z),
    );
  });

  test('scrolling maximize keeps native off-screen strip geometry', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const viewSize = Size(1920, 1080);
    const maximizedFrame = Rect.fromLTWH(8, 40, 1904, 1032);
    const maximizedContent = Rect.fromLTWH(9, 41, 1902, 1030);
    final maximized = nativeWindow(
      objectKind: 'xdg',
      geometry: maximizedContent,
      fullscreen: false,
      maximized: true,
    );

    workspace.syncWindows(
      <DenialWindow>[maximized],
      viewSize,
      1,
      snapshotSequence: 20,
      windowLayout: DesktopWindowLayout.scrolling,
    );
    workspace.syncWorkAreas(const <int, Rect>{
      1: Rect.fromLTWH(8, 40, 1904, 1032),
    });
    expect(
      container.read(desktopWorkspaceProvider).placements[7]!.frame,
      maximizedFrame,
    );

    const scrolledContent = Rect.fromLTWH(-1905, 41, 1902, 1030);
    const scrolledFrame = Rect.fromLTWH(-1906, 40, 1904, 1032);
    expect(
      workspace.applyNativePlacement(
        7,
        const DenialWindowPlacementEvent(
          sequence: 21,
          windowId: 27,
          contentRect: scrolledContent,
          monitorId: 1,
          workspaceId: 1,
          phase: DenialWindowPlacementPhase.update,
          change: DenialWindowPlacementChange.move,
        ),
      ),
      isTrue,
    );
    final placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.maximized, isTrue);
    expect(placement.frame, scrolledFrame);
    expect(placement.contentRect, scrolledContent);
    expect(placement.drawsLiveServerFrame, isTrue);
    expect(placement.frameBorder, DesktopMetrics.frameBorder);
  });

  test('stacking maximize remains frameless', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const geometry = Rect.fromLTWH(8, 40, 1904, 1032);

    workspace.syncWindows(
      <DenialWindow>[
        nativeWindow(
          objectKind: 'xdg',
          geometry: geometry,
          fullscreen: false,
          maximized: true,
        ),
      ],
      const Size(1920, 1080),
      1,
      snapshotSequence: 25,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.frame, geometry);
    expect(placement.drawsLiveServerFrame, isFalse);
    expect(placement.frameBorder, 0);
  });

  test('dwindle maximize keeps the rounded server frame', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const content = Rect.fromLTWH(9, 41, 1902, 1030);

    workspace.syncWindows(
      <DenialWindow>[
        nativeWindow(
          objectKind: 'xdg',
          geometry: content,
          fullscreen: false,
          maximized: true,
        ),
      ],
      const Size(1920, 1080),
      1,
      snapshotSequence: 26,
      windowLayout: DesktopWindowLayout.dwindle,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.frame, const Rect.fromLTWH(8, 40, 1904, 1032));
    expect(placement.contentRect, content);
    expect(placement.drawsLiveServerFrame, isTrue);
  });

  test('late layout restore rebases a replacement runtime from native geometry', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const content = Rect.fromLTWH(9, 41, 1902, 1030);
    final window = nativeWindow(
      objectKind: 'xdg',
      geometry: content,
      fullscreen: false,
      maximized: true,
    );

    // A replacement Dart isolate can receive the scene snapshot before the
    // persisted tiling setting. Its initial default is stacking.
    workspace.syncWindows(
      <DenialWindow>[window],
      const Size(1920, 1080),
      1,
      snapshotSequence: 27,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[7]!.frame,
      content,
    );

    // Loading settings does not produce another native scene revision. The
    // same snapshot must still be reinterpreted with managed-layout framing.
    workspace.syncWindows(
      <DenialWindow>[window],
      const Size(1920, 1080),
      1,
      snapshotSequence: 27,
      windowLayout: DesktopWindowLayout.dwindle,
    );
    final placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.frame, const Rect.fromLTWH(8, 40, 1904, 1032));
    expect(placement.contentRect, content);
    expect(placement.serverFrameWhileMaximized, isTrue);
  });

  test('local maximize-fullscreen-maximize-restore is reversible', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const viewSize = Size(1920, 1080);
    const normal = Rect.fromLTWH(200, 120, 900, 700);
    const maximized = Rect.fromLTWH(8, 40, 1904, 1032);
    const fullscreen = Rect.fromLTWH(0, 0, 1920, 1080);
    final window = nativeWindow(
      objectKind: 'flutter',
      geometry: normal,
      fullscreen: false,
      contentKind: DenialWindowContentKind.localFlutter,
    );

    workspace.syncWindows(
      <DenialWindow>[window],
      viewSize,
      1,
      snapshotSequence: 27,
    );
    final normalFrame = container
        .read(desktopWorkspaceProvider)
        .placements[7]!
        .frame;
    workspace.applyFlutterOwnedWindowAction(
      window,
      DenialWindowAction.toggleMaximize,
      maximizeBounds: maximized,
      fullscreenBounds: fullscreen,
    );
    expect(
      workspace.applyFlutterOwnedWindowAction(
        window,
        DenialWindowAction.toggleFullscreen,
        maximizeBounds: maximized,
        fullscreenBounds: fullscreen,
      ),
      isTrue,
    );
    workspace.applyFlutterOwnedWindowAction(
      window,
      DenialWindowAction.toggleMaximize,
      maximizeBounds: maximized,
      fullscreenBounds: fullscreen,
    );

    var placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.fullscreen, isFalse);
    expect(placement.maximized, isTrue);
    expect(placement.frame, maximized);
    expect(placement.restoreFrame, normalFrame);

    workspace.applyFlutterOwnedWindowAction(
      window,
      DenialWindowAction.toggleMaximize,
      maximizeBounds: maximized,
      fullscreenBounds: fullscreen,
    );
    placement = container.read(desktopWorkspaceProvider).placements[7]!;
    expect(placement.fullscreen, isFalse);
    expect(placement.maximized, isFalse);
    expect(placement.frame, normalFrame);
  });

  test('only a begun move marks a scrolling tile as actively dragged', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    const viewSize = Size(3840, 1080);
    const initial = Rect.fromLTWH(100, 50, 600, 500);

    workspace.syncWindows(
      <DenialWindow>[
        nativeWindow(objectKind: 'xdg', geometry: initial, fullscreen: false),
      ],
      viewSize,
      1,
      snapshotSequence: 30,
      windowLayout: DesktopWindowLayout.scrolling,
    );

    for (final event in const <DenialWindowPlacementEvent>[
      DenialWindowPlacementEvent(
        sequence: 31,
        windowId: 27,
        contentRect: Rect.fromLTWH(2000, 50, 700, 500),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.begin,
        change: DenialWindowPlacementChange.resize,
      ),
      DenialWindowPlacementEvent(
        sequence: 32,
        windowId: 27,
        contentRect: Rect.fromLTWH(2000, 50, 750, 500),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.update,
        change: DenialWindowPlacementChange.resize,
      ),
      DenialWindowPlacementEvent(
        sequence: 33,
        windowId: 27,
        contentRect: Rect.fromLTWH(2050, 50, 750, 500),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.update,
        change: DenialWindowPlacementChange.move,
      ),
    ]) {
      expect(workspace.applyNativePlacement(7, event), isTrue);
      expect(
        container.read(desktopWorkspaceProvider).placements[7]!.dragging,
        isFalse,
      );
    }

    expect(
      workspace.applyNativePlacement(
        7,
        const DenialWindowPlacementEvent(
          sequence: 34,
          windowId: 27,
          contentRect: Rect.fromLTWH(2100, 50, 750, 500),
          monitorId: 1,
          workspaceId: 1,
          phase: DenialWindowPlacementPhase.begin,
          change: DenialWindowPlacementChange.move,
        ),
      ),
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[7]!.dragging,
      isTrue,
    );

    expect(
      workspace.applyNativePlacement(
        7,
        const DenialWindowPlacementEvent(
          sequence: 35,
          windowId: 27,
          contentRect: Rect.fromLTWH(2150, 50, 750, 500),
          monitorId: 1,
          workspaceId: 1,
          phase: DenialWindowPlacementPhase.end,
          change: DenialWindowPlacementChange.move,
        ),
      ),
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[7]!.dragging,
      isFalse,
    );
  });
}
