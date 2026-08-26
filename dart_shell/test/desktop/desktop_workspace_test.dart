import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/desktop/desktop_overview_layout.dart';
import 'package:denial_dart_shell/src/desktop/desktop_overview_target.dart';
import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/state/desktop_window_switcher.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';

List<List<int>> _orderedOverviewRows(Map<int, Rect> frames) {
  final entries = frames.entries.toList(growable: false)
    ..sort((left, right) {
      final vertical = left.value.top.compareTo(right.value.top);
      return vertical != 0
          ? vertical
          : left.value.left.compareTo(right.value.left);
    });
  final rows = <List<int>>[];
  double? currentTop;
  for (final entry in entries) {
    if (currentTop == null || (entry.value.top - currentTop).abs() > 0.001) {
      rows.add(<int>[]);
      currentTop = entry.value.top;
    }
    rows.last.add(entry.key);
  }
  return rows;
}

void main() {
  const viewSize = Size(5120, 1440);
  const secondOutput = Rect.fromLTWH(2560, 0, 2560, 1440);

  test('overview position curves ease smoothly at both endpoints', () {
    for (final curve in <Curve>[
      Motion.overviewEnterCurve,
      Motion.overviewExitCurve,
    ]) {
      expect(curve.transform(0.01), lessThan(0.001));
      expect(1.0 - curve.transform(0.99), lessThan(0.001));
    }
    expect(Motion.overviewEnterCurve.transform(0.5), greaterThan(0.75));
    expect(Motion.overviewExitCurve.transform(0.5), closeTo(0.5, 0.001));
    expect(Motion.overviewReversalCurve.transform(0.01), greaterThan(0.003));
    expect(1.0 - Motion.overviewReversalCurve.transform(0.99), lessThan(0.001));
  });

  test('window switcher replaces a source that leaves the candidate set', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWindowSwitcherProvider.notifier);
    controller.beginOrAdvance(
      objectIds: const <int>[1, 2, 3],
      sourceObjectId: 1,
      usesDesktopMotion: false,
    );

    final reconciled = controller.beginOrAdvance(
      objectIds: const <int>[2, 3],
      sourceObjectId: 2,
      usesDesktopMotion: false,
    );

    expect(reconciled?.sourceObjectId, 2);
    expect(reconciled?.objectIds, <int>[2, 3]);
  });

  test('window switcher starts directly from an all-minimized candidate', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWindowSwitcherProvider.notifier);

    final started = controller.beginOrAdvance(
      objectIds: const <int>[3, 2, 1],
      sourceObjectId: null,
      usesDesktopMotion: true,
    );

    expect(started?.sourceObjectId, isNull);
    expect(started?.selectedObjectId, 3);
    expect(started?.selectedIndex, 0);
    expect(started?.usesExpandedTransition, isTrue);
  });

  test('source-less window switcher cycles without inventing a source', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWindowSwitcherProvider.notifier);
    controller.beginOrAdvance(
      objectIds: const <int>[3, 2, 1],
      sourceObjectId: null,
      usesDesktopMotion: true,
    );

    final advanced = controller.beginOrAdvance(
      objectIds: const <int>[3, 2, 1],
      sourceObjectId: null,
      usesDesktopMotion: true,
    );

    expect(advanced?.sourceObjectId, isNull);
    expect(advanced?.selectedObjectId, 2);
  });

  test('window switcher starts and cycles backward for right swipes', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWindowSwitcherProvider.notifier);

    final started = controller.beginOrAdvance(
      objectIds: const <int>[1, 2, 3],
      sourceObjectId: 1,
      usesDesktopMotion: false,
      direction: DesktopWindowSwitcherDirection.previous,
    );
    final advanced = controller.beginOrAdvance(
      objectIds: const <int>[1, 2, 3],
      sourceObjectId: 1,
      usesDesktopMotion: false,
      direction: DesktopWindowSwitcherDirection.previous,
    );

    expect(started?.selectedObjectId, 3);
    expect(advanced?.selectedObjectId, 2);
  });

  test('active window switcher can reverse direction without restarting', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWindowSwitcherProvider.notifier);

    final started = controller.beginOrAdvance(
      objectIds: const <int>[1, 2, 3],
      sourceObjectId: 1,
      usesDesktopMotion: false,
    )!;
    final reversed = controller.beginOrAdvance(
      objectIds: const <int>[1, 2, 3],
      sourceObjectId: 1,
      usesDesktopMotion: false,
      direction: DesktopWindowSwitcherDirection.previous,
    );

    expect(started.selectedObjectId, 2);
    expect(reversed?.sessionId, started.sessionId);
    expect(reversed?.selectedObjectId, 1);
  });

  test('source-less window switcher can restore its only candidate', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWindowSwitcherProvider.notifier);

    final started = controller.beginOrAdvance(
      objectIds: const <int>[7],
      sourceObjectId: null,
      usesDesktopMotion: true,
    );

    expect(started?.selectedObjectId, 7);
  });

  test('new windows preserve compositor-assigned geometry', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const nativeGeometry = Rect.fromLTWH(3000, 220, 420, 260);

    controller.syncWindows(
      <DenialWindow>[
        _window(
          objectId: 1,
          windowId: 11,
          monitorId: 2,
          geometry: nativeGeometry,
        ),
      ],
      viewSize,
      1,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.contentRect, nativeGeometry);
  });

  test('undecorated windows use native content geometry as their frame', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const nativeGeometry = Rect.fromLTWH(3000, 220, 420, 260);

    controller.syncWindows(
      <DenialWindow>[
        _window(
          objectId: 1,
          windowId: 11,
          monitorId: 2,
          geometry: nativeGeometry,
          serverSideDecorated: false,
        ),
      ],
      viewSize,
      1,
      snapshotSequence: 1,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.serverSideDecorated, isFalse);
    expect(placement.frame, nativeGeometry);
    expect(placement.contentRect, nativeGeometry);
  });

  test('decoration changes preserve the client content rectangle', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const nativeGeometry = Rect.fromLTWH(3000, 220, 420, 260);

    controller.syncWindows(
      <DenialWindow>[
        _window(
          objectId: 1,
          windowId: 11,
          monitorId: 2,
          geometry: nativeGeometry,
        ),
      ],
      viewSize,
      1,
      snapshotSequence: 1,
    );
    controller.syncWindows(
      <DenialWindow>[
        _window(
          objectId: 1,
          windowId: 11,
          monitorId: 2,
          geometry: Rect.zero,
          serverSideDecorated: false,
        ),
      ],
      viewSize,
      1,
      snapshotSequence: 2,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.serverSideDecorated, isFalse);
    expect(placement.frame, nativeGeometry);
    expect(placement.contentRect, nativeGeometry);
  });

  test('window snapshots do not rewrite native initial geometry', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final windows = <DenialWindow>[
      _window(objectId: 1, windowId: 11, monitorId: 2, geometry: secondOutput),
    ];

    controller.syncWindows(windows, viewSize, 1);
    controller.syncWindows(windows, viewSize, 1);

    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.contentRect,
      secondOutput,
    );
  });

  test(
    'windows wait for native geometry instead of using a shell fallback',
    () {
      final container = ProviderContainer.test();
      final controller = container.read(desktopWorkspaceProvider.notifier);

      controller.syncWindows(
        <DenialWindow>[
          _window(objectId: 1, windowId: 11, monitorId: 1, geometry: Rect.zero),
        ],
        viewSize,
        1,
      );

      expect(container.read(desktopWorkspaceProvider).placements, isEmpty);
    },
  );

  test('native geometry updates are mirrored without Flutter clamping', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final window = _window(objectId: 1, windowId: 11, monitorId: 1);
    controller.syncWindows(<DenialWindow>[window], viewSize, 1);

    const animatedPopupGeometry = Rect.fromLTWH(2277, 1500, 283, 70);
    controller.applyNativePlacement(
      1,
      _placementEvent(
        sequence: 1,
        contentRect: animatedPopupGeometry,
        monitorId: 1,
        workspaceId: 1,
      ),
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.contentRect, animatedPopupGeometry);
    expect(placement.dragging, isFalse);
  });

  test('fullscreen keeps normal stacking and locks geometry', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final windows = <DenialWindow>[
      _window(objectId: 1, windowId: 11, monitorId: 1),
      _window(objectId: 2, windowId: 22, monitorId: 1),
      _window(
        objectId: 3,
        windowId: 33,
        monitorId: 1,
        geometry: const Rect.fromLTWH(200, 100, 160, 20),
      ),
    ];
    controller.syncWindows(windows, viewSize, 1);
    final restoreFrame = container
        .read(desktopWorkspaceProvider)
        .placements[1]!
        .frame;

    const fullscreenBounds = Rect.fromLTWH(0, 0, 2560, 1440);
    controller.toggleFullscreen(1, bounds: fullscreenBounds);

    final fullscreen = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(fullscreen.fullscreen, isTrue);
    expect(fullscreen.frame, fullscreenBounds);
    expect(fullscreen.contentRect, fullscreenBounds);
    expect(
      fullscreen.z,
      lessThan(container.read(desktopWorkspaceProvider).placements[2]!.z),
    );

    controller.beginMove(1);
    controller.moveBy(1, const Offset(120, 80));
    controller.applyNativePlacement(
      1,
      _placementEvent(
        sequence: 1,
        contentRect: const Rect.fromLTWH(50, 60, 800, 600),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.update,
      ),
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      fullscreenBounds,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.dragging,
      isFalse,
    );

    controller.activate(1);
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.z,
      greaterThan(container.read(desktopWorkspaceProvider).placements[2]!.z),
    );
    controller.activate(2);
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.z,
      greaterThan(container.read(desktopWorkspaceProvider).placements[1]!.z),
    );

    controller.toggleFullscreen(1, bounds: fullscreenBounds);
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.fullscreen,
      isFalse,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      restoreFrame,
    );
  });

  test(
    'pinned windows stack above ordinary windows without changing focus z',
    () {
      final windows = <DenialWindow>[
        _window(objectId: 1, windowId: 11, monitorId: 1),
        _window(objectId: 2, windowId: 22, monitorId: 1, pinned: true),
        _window(objectId: 3, windowId: 33, monitorId: 1, pinned: true),
      ];
      final windowsById = <int, DenialWindow>{
        for (final window in windows) window.objectId: window,
      };
      final placements = <DesktopWindowPlacement>[
        const DesktopWindowPlacement(
          objectId: 2,
          frame: Rect.fromLTWH(0, 0, 100, 100),
          z: 1,
          monitorId: 1,
        ),
        const DesktopWindowPlacement(
          objectId: 3,
          frame: Rect.fromLTWH(0, 0, 100, 100),
          z: 2,
          monitorId: 1,
        ),
        const DesktopWindowPlacement(
          objectId: 1,
          frame: Rect.fromLTWH(0, 0, 100, 100),
          z: 99,
          monitorId: 1,
        ),
      ]..sort((a, b) => compareDesktopWindowStack(a, b, windowsById));

      expect(placements.map((placement) => placement.objectId), <int>[1, 2, 3]);
      expect(placements.last.z, 2, reason: 'pinning must not rewrite focus z');
    },
  );

  test('desktop hit testing returns the visually topmost window', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final windows = <DenialWindow>[
      _window(objectId: 1, windowId: 11, monitorId: 1),
      _window(objectId: 2, windowId: 22, monitorId: 1, pinned: true),
    ];
    controller.syncWindows(windows, viewSize, 1);

    final windowsById = <int, DenialWindow>{
      for (final window in windows) window.objectId: window,
    };
    final hit = desktopWindowAtPosition(
      position: container
          .read(desktopWorkspaceProvider)
          .placements[1]!
          .frame
          .center,
      workspace: container.read(desktopWorkspaceProvider),
      windowsById: windowsById,
    );

    expect(hit?.objectId, 2);
    expect(
      desktopWindowAtPosition(
        position: const Offset(10, 10),
        workspace: container.read(desktopWorkspaceProvider),
        windowsById: windowsById,
      ),
      isNull,
    );
  });

  test('monitor transfer moves fullscreen frame and restore geometry', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final window = _window(objectId: 1, windowId: 11, monitorId: 1);
    controller.syncWindows(<DenialWindow>[window], viewSize, 1);
    final restoreFrame = container
        .read(desktopWorkspaceProvider)
        .placements[1]!
        .frame;

    const sourceBounds = Rect.fromLTWH(0, 0, 2560, 1440);
    const targetBounds = Rect.fromLTWH(2560, 0, 2560, 1440);
    controller.toggleFullscreen(1, bounds: sourceBounds);

    controller.applyNativePlacement(
      1,
      _placementEvent(
        sequence: 1,
        contentRect: targetBounds,
        monitorId: 2,
        workspaceId: 2,
      ),
    );

    final transferred = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(transferred.fullscreen, isTrue);
    expect(transferred.frame, targetBounds);
    expect(transferred.monitorId, 2);
    expect(transferred.workspaceId, 2);
    expect(transferred.dragging, isFalse);

    controller.toggleFullscreen(1, bounds: targetBounds);
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.fullscreen,
      isFalse,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      restoreFrame.shift(const Offset(2560, 0)),
    );
  });

  test('overview drag transfers a normal window to another monitor', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final window = _window(objectId: 1, windowId: 11, monitorId: 1);
    controller.syncWindows(<DenialWindow>[window], viewSize, 1);
    controller.toggleOverview(
      monitorId: 1,
      bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      backgroundBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      objectIds: const <int>{1},
    );

    final raisedZ = container.read(desktopWorkspaceProvider).nextZ;
    controller.beginOverviewDrag(1);
    controller.moveOverviewBy(1, const Offset(2560, 0));
    final previewCenter = container
        .read(desktopWorkspaceProvider)
        .overview!
        .frames[1]!
        .center;
    final transferred = controller.endOverviewDrag(
      1,
      outputBounds: const <int, Rect>{
        1: Rect.fromLTWH(0, 0, 2560, 1440),
        2: secondOutput,
      },
      workAreas: const <int, Rect>{
        1: Rect.fromLTWH(0, 0, 2560, 1440),
        2: secondOutput,
      },
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(transferred, isTrue);
    expect(container.read(desktopWorkspaceProvider).overview, isNull);
    expect(placement.monitorId, 2);
    expect(placement.dragging, isFalse);
    expect(placement.z, raisedZ);
    expect(container.read(desktopWorkspaceProvider).nextZ, raisedZ + 1);
    expect(placement.frame.center, previewCenter);
    expect(secondOutput.contains(placement.frame.topLeft), isTrue);
    expect(
      secondOutput.contains(placement.frame.bottomRight - const Offset(1, 1)),
      isTrue,
    );
  });

  test('overview drag raises every window state for the whole gesture', () {
    for (final mode in <String>['normal', 'maximized', 'fullscreen']) {
      final container = ProviderContainer.test();
      final controller = container.read(desktopWorkspaceProvider.notifier);
      controller.syncWindows(
        <DenialWindow>[
          _window(objectId: 1, windowId: 11, monitorId: 1),
          _window(objectId: 2, windowId: 22, monitorId: 2),
        ],
        viewSize,
        1,
      );
      if (mode != 'normal') {
        controller.toggleMaximized(
          1,
          bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
        );
      }
      if (mode == 'fullscreen') {
        controller.toggleFullscreen(
          1,
          bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
        );
      }
      controller.toggleOverview(
        monitorId: 1,
        bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
        backgroundBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
        objectIds: const <int>{1},
      );

      final original = container.read(desktopWorkspaceProvider).placements[1]!;
      final blockingZ = container
          .read(desktopWorkspaceProvider)
          .placements[2]!
          .z;
      final raisedZ = container.read(desktopWorkspaceProvider).nextZ;
      expect(original.z, lessThan(blockingZ), reason: mode);

      controller.beginOverviewDrag(1);

      final dragging = container.read(desktopWorkspaceProvider).placements[1]!;
      expect(dragging.dragging, isTrue, reason: mode);
      expect(dragging.z, raisedZ, reason: mode);
      expect(dragging.z, greaterThan(blockingZ), reason: mode);
      expect(
        container.read(desktopWorkspaceProvider).nextZ,
        raisedZ + 1,
        reason: mode,
      );
      expect(dragging.frame, original.frame, reason: mode);
      expect(dragging.maximized, original.maximized, reason: mode);
      expect(dragging.fullscreen, original.fullscreen, reason: mode);
      expect(dragging.restoreFrame, original.restoreFrame, reason: mode);
      expect(
        dragging.fullscreenRestoreFrame,
        original.fullscreenRestoreFrame,
        reason: mode,
      );

      controller.cancelOverviewDrag(1);
      final cancelled = container.read(desktopWorkspaceProvider).placements[1]!;
      expect(cancelled.dragging, isFalse, reason: mode);
      expect(cancelled.z, original.z, reason: mode);
    }
  });

  test('cancelled overview drag restores its arranged preview', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final window = _window(objectId: 1, windowId: 11, monitorId: 1);
    controller.syncWindows(<DenialWindow>[window], viewSize, 1);
    controller.toggleOverview(
      monitorId: 1,
      bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      backgroundBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      objectIds: const <int>{1},
    );
    final origin = container.read(desktopWorkspaceProvider).overview!.frames[1];

    controller.beginOverviewDrag(1);
    controller.moveOverviewBy(1, const Offset(240, 120));
    expect(
      container.read(desktopWorkspaceProvider).overview!.frames[1],
      isNot(origin),
    );
    controller.cancelOverviewDrag(1);

    expect(
      container.read(desktopWorkspaceProvider).overview!.frames[1],
      origin,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.dragging,
      isFalse,
    );
  });

  test('overview transfer preserves maximized restore geometry', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final window = _window(objectId: 1, windowId: 11, monitorId: 1);
    controller.syncWindows(<DenialWindow>[window], viewSize, 1);
    final originalFrame = container
        .read(desktopWorkspaceProvider)
        .placements[1]!
        .frame;
    controller.toggleMaximized(
      1,
      bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
    );
    controller.toggleOverview(
      monitorId: 1,
      bounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      backgroundBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
      objectIds: const <int>{1},
    );

    controller.beginOverviewDrag(1);
    controller.moveOverviewBy(1, const Offset(2560, 0));
    expect(
      controller.endOverviewDrag(
        1,
        outputBounds: const <int, Rect>{
          1: Rect.fromLTWH(0, 0, 2560, 1440),
          2: secondOutput,
        },
        workAreas: const <int, Rect>{
          1: Rect.fromLTWH(0, 0, 2560, 1440),
          2: secondOutput,
        },
      ),
      isTrue,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.maximized, isTrue);
    expect(placement.frame, secondOutput);
    expect(placement.restoreFrame, originalFrame.shift(const Offset(2560, 0)));
  });

  test(
    'newer snapshots reconcile placement but older snapshots cannot roll it back',
    () {
      final container = ProviderContainer.test();
      final controller = container.read(desktopWorkspaceProvider.notifier);
      final source = _window(objectId: 1, windowId: 11, monitorId: 1);
      controller.syncWindows(
        <DenialWindow>[source],
        viewSize,
        1,
        snapshotSequence: 10,
      );

      const targetGeometry = Rect.fromLTWH(3520, 520, 640, 400);
      controller.applyNativePlacement(
        1,
        _placementEvent(
          sequence: 12,
          contentRect: targetGeometry,
          monitorId: 2,
          workspaceId: 2,
        ),
      );

      controller.syncWindows(
        <DenialWindow>[source],
        viewSize,
        1,
        snapshotSequence: 11,
      );
      expect(
        container.read(desktopWorkspaceProvider).placements[1]!.monitorId,
        2,
      );
      expect(
        container.read(desktopWorkspaceProvider).placements[1]!.contentRect,
        targetGeometry,
      );

      controller.syncWindows(
        <DenialWindow>[
          _window(
            objectId: 1,
            windowId: 11,
            monitorId: 1,
            geometry: const Rect.fromLTWH(800, 300, 700, 500),
          ),
        ],
        viewSize,
        1,
        snapshotSequence: 13,
      );
      expect(
        container.read(desktopWorkspaceProvider).placements[1]!.monitorId,
        1,
      );
      expect(
        container.read(desktopWorkspaceProvider).placements[1]!.contentRect,
        const Rect.fromLTWH(800, 300, 700, 500),
      );
    },
  );

  test(
    'presentation-only snapshots advance ordering without changing workspace',
    () {
      final container = ProviderContainer.test();
      final controller = container.read(desktopWorkspaceProvider.notifier);
      controller.syncWindows(
        <DenialWindow>[
          _window(objectId: 1, windowId: 11, monitorId: 1, title: 'Building ⠼'),
        ],
        viewSize,
        1,
        snapshotSequence: 10,
      );
      final before = container.read(desktopWorkspaceProvider);

      controller.syncWindows(
        <DenialWindow>[
          _window(objectId: 1, windowId: 11, monitorId: 1, title: 'Building ⠴'),
        ],
        viewSize,
        1,
        snapshotSequence: 11,
      );

      expect(container.read(desktopWorkspaceProvider), same(before));

      controller.applyNativePlacement(
        1,
        _placementEvent(
          sequence: 11,
          contentRect: const Rect.fromLTWH(100, 100, 300, 200),
          monitorId: 1,
          workspaceId: 1,
        ),
      );
      expect(container.read(desktopWorkspaceProvider), same(before));
    },
  );

  test('native grab geometry ignores interleaved title snapshots', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    controller.syncWindows(
      <DenialWindow>[
        _window(objectId: 1, windowId: 11, monitorId: 1, title: 'Thinking ⠼'),
      ],
      viewSize,
      1,
      snapshotSequence: 10,
    );
    controller.applyNativePlacement(
      1,
      _placementEvent(
        sequence: 11,
        contentRect: const Rect.fromLTWH(100, 100, 300, 200),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.begin,
      ),
    );
    final grabAnchor = container.read(desktopWorkspaceProvider);
    expect(grabAnchor.placements[1]!.dragging, isTrue);

    controller.syncWindows(
      <DenialWindow>[
        _window(
          objectId: 1,
          windowId: 11,
          monitorId: 1,
          title: 'Thinking ⠴',
          geometry: const Rect.fromLTWH(460, 380, 300, 200),
        ),
      ],
      viewSize,
      1,
      snapshotSequence: 12,
    );

    expect(container.read(desktopWorkspaceProvider), same(grabAnchor));
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.contentRect,
      const Rect.fromLTWH(100, 100, 300, 200),
    );

    controller.applyNativePlacement(
      1,
      _placementEvent(
        sequence: 13,
        contentRect: const Rect.fromLTWH(460, 380, 300, 200),
        monitorId: 1,
        workspaceId: 1,
        phase: DenialWindowPlacementPhase.end,
      ),
    );
    final settled = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(settled.dragging, isFalse);
    expect(settled.contentRect, const Rect.fromLTWH(460, 380, 300, 200));
  });

  test(
    'live placement geometry does not invalidate static scene structure',
    () {
      const original = DesktopWindowPlacement(
        objectId: 1,
        frame: Rect.fromLTWH(100, 120, 800, 600),
        z: 3,
        monitorId: 1,
        dragging: true,
      );
      final before = DesktopWorkspaceState(
        placements: const <int, DesktopWindowPlacement>{1: original},
        nextZ: 4,
        viewSize: viewSize,
      );
      final moved = before.copyWith(
        placements: <int, DesktopWindowPlacement>{
          1: original.copyWith(frame: const Rect.fromLTWH(400, 360, 800, 600)),
        },
      );
      final resized = before.copyWith(
        placements: <int, DesktopWindowPlacement>{
          1: original.copyWith(frame: const Rect.fromLTWH(100, 120, 900, 600)),
        },
      );
      final settled = moved.copyWith(
        placements: <int, DesktopWindowPlacement>{
          1: moved.placements[1]!.copyWith(dragging: false),
        },
      );
      final idle = before.copyWith(
        placements: <int, DesktopWindowPlacement>{
          1: original.copyWith(dragging: false),
        },
      );
      final idleResized = idle.copyWith(
        placements: <int, DesktopWindowPlacement>{
          1: idle.placements[1]!.copyWith(
            frame: const Rect.fromLTWH(100, 120, 900, 600),
          ),
        },
      );

      expect(desktopWorkspaceHasSameSceneStructure(before, moved), isTrue);
      expect(desktopWorkspaceHasSameSceneStructure(before, resized), isTrue);
      expect(desktopWorkspaceHasSameSceneStructure(moved, settled), isFalse);
      expect(desktopWorkspaceHasSameSceneStructure(idle, idleResized), isFalse);
    },
  );

  test('input layout revision ignores panel-only workspace updates', () {
    final initial = DesktopWorkspaceState.initial();
    final panel = initial.copyWith(panel: DesktopPanel.launcher);
    final placement = panel.copyWith(
      placements: const <int, DesktopWindowPlacement>{
        1: DesktopWindowPlacement(
          objectId: 1,
          frame: Rect.fromLTWH(10, 20, 640, 480),
          z: 1,
          monitorId: 1,
        ),
      },
    );

    expect(panel.inputLayoutRevision, initial.inputLayoutRevision);
    expect(
      identical(panel.placements, initial.placements),
      isTrue,
      reason: 'panel visibility must not clone the complete window map',
    );
    expect(placement.inputLayoutRevision, panel.inputLayoutRevision + 1);
  });

  test('panel-only updates do not invalidate the base desktop scene', () {
    final initial = DesktopWorkspaceState.initial();
    final launcher = initial.copyWith(panel: DesktopPanel.launcher);
    final dashboard = launcher.copyWith(panel: DesktopPanel.dashboard);

    expect(desktopWorkspaceHasSameSceneStructure(initial, launcher), isTrue);
    expect(desktopWorkspaceHasSameSceneStructure(launcher, dashboard), isTrue);
  });

  test('live visual frame follows every resized placement edge', () {
    const visualFrame = Rect.fromLTWH(110, 130, 800, 600);
    const placementFrame = Rect.fromLTWH(100, 120, 800, 600);
    const livePlacementFrame = Rect.fromLTRB(80, 90, 940, 760);

    expect(
      desktopLivePlacementVisualFrame(
        visualFrame: visualFrame,
        placementFrame: placementFrame,
        livePlacementFrame: livePlacementFrame,
      ),
      const Rect.fromLTRB(90, 100, 950, 770),
    );
  });

  test(
    'overview target follows ownership and excludes tiny switcher entries',
    () {
      final container = ProviderContainer.test();
      final controller = container.read(desktopWorkspaceProvider.notifier);
      final windows = <DenialWindow>[
        _window(objectId: 1, windowId: 11, monitorId: 1),
        _window(objectId: 2, windowId: 22, monitorId: 1),
      ];
      controller.syncWindows(windows, viewSize, 1);

      controller.applyNativePlacement(
        1,
        _placementEvent(
          sequence: 1,
          contentRect: const Rect.fromLTWH(3520, 520, 640, 400),
          monitorId: 2,
          workspaceId: 2,
        ),
      );

      final left = DesktopOverviewTarget.resolve(
        viewSize: viewSize,
        displayLayout: _displayLayout,
        windows: windows,
        workspace: container.read(desktopWorkspaceProvider),
        foregroundObjectId: 1,
        preferredMonitorId: 1,
      );
      final right = DesktopOverviewTarget.resolve(
        viewSize: viewSize,
        displayLayout: _displayLayout,
        windows: windows,
        workspace: container.read(desktopWorkspaceProvider),
        foregroundObjectId: 1,
        preferredMonitorId: 2,
      );

      expect(left?.objectIds, <int>{2});
      expect(right?.objectIds, <int>{1});
    },
  );

  test('minimized desktop widgets still participate in overview', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    final windows = <DenialWindow>[
      _window(objectId: 1, windowId: 11, monitorId: 1),
      _window(objectId: 2, windowId: 22, monitorId: 1),
    ];
    controller.syncWindows(windows, viewSize, 1);
    final nativeFrame = container
        .read(desktopWorkspaceProvider)
        .placements[2]!
        .frame;

    controller.minimize(2);

    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.minimized,
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.frame,
      nativeFrame,
    );
    final target = DesktopOverviewTarget.resolve(
      viewSize: viewSize,
      displayLayout: _displayLayout,
      windows: windows,
      workspace: container.read(desktopWorkspaceProvider),
      foregroundObjectId: 2,
      preferredMonitorId: 1,
    );
    expect(target?.objectIds, <int>{1, 2});

    controller.activate(2);
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.minimized,
      isFalse,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.frame,
      nativeFrame,
    );
  });

  test('overview never enlarges a window frame', () {
    const items = <DesktopOverviewItem>[
      DesktopOverviewItem(
        objectId: 1,
        frame: Rect.fromLTWH(80, 100, 320, 240),
        z: 1,
      ),
      DesktopOverviewItem(
        objectId: 2,
        frame: Rect.fromLTWH(520, 280, 480, 270),
        z: 2,
      ),
    ];

    final frames = DesktopOverviewLayout.arrange(
      items: items,
      bounds: const Rect.fromLTWH(0, 0, 1920, 1080),
    );

    expect(frames, hasLength(items.length));
    for (final item in items) {
      final frame = frames[item.objectId]!;
      expect(frame.width, lessThanOrEqualTo(item.frame.width));
      expect(frame.height, lessThanOrEqualTo(item.frame.height));
    }
  });

  test('overview excludes windows too small to make useful previews', () {
    const items = <DesktopOverviewItem>[
      DesktopOverviewItem(
        objectId: 1,
        frame: Rect.fromLTWH(80, 100, 900, 500),
        z: 1,
      ),
      DesktopOverviewItem(
        objectId: 2,
        frame: Rect.fromLTWH(1100, 320, 80, 50),
        z: 2,
      ),
    ];

    final frames = DesktopOverviewLayout.arrange(
      items: items,
      bounds: const Rect.fromLTWH(0, 0, 1400, 800),
    );
    expect(frames.keys.toSet(), <int>{1});
    expect(frames[1], isNotNull);
    expect(frames[2], isNull);
    expect(
      DesktopOverviewLayout.isUsefulPreview(const Rect.fromLTWH(0, 0, 160, 20)),
      isFalse,
    );
  });

  test('overview retains an ordered 16x9 layout for 144 windows', () {
    final items = <DesktopOverviewItem>[
      for (var index = 0; index < 144; index += 1)
        DesktopOverviewItem(
          objectId: index,
          frame: const Rect.fromLTWH(383, 383, 160, 146),
          z: index + 1,
        ),
    ];

    final frames = DesktopOverviewLayout.arrange(
      items: items,
      bounds: const Rect.fromLTRB(0, 45, 2560, 1440),
    );

    expect(frames, hasLength(items.length));
    final rows = _orderedOverviewRows(frames);
    expect(rows, hasLength(9));
    expect(rows.every((row) => row.length == 16), isTrue);
    expect(rows.expand((row) => row), <int>[
      for (var index = 0; index < 144; index += 1) index,
    ]);
  });

  test('desktop panels and hover triggers use the left screen corners', () {
    final launcher = DesktopMetrics.launcherRect(
      viewSize,
      outputRect: secondOutput,
    );
    final dashboard = DesktopMetrics.dashboardRect(
      viewSize,
      outputRect: secondOutput,
    );
    final launcherTrigger = DesktopMetrics.launcherTriggerRect(
      viewSize,
      outputRect: secondOutput,
    );
    final dashboardTrigger = DesktopMetrics.dashboardTriggerRect(
      viewSize,
      outputRect: secondOutput,
    );

    expect(launcher, const Rect.fromLTWH(2574, 14, 680, 620));
    expect(dashboard, const Rect.fromLTWH(2574, 806, 470, 620));
    expect(launcherTrigger, const Rect.fromLTWH(2560, 0, 14, 620));
    expect(dashboardTrigger, const Rect.fromLTWH(2560, 820, 14, 620));
  });

  test('desktop panels and hover triggers follow configured anchors', () {
    const placement = ShellPopupPlacement(
      anchor: ShellPopupAnchor.topRight,
      width: 640,
      height: 500,
      margin: 24,
    );

    expect(
      DesktopMetrics.launcherRect(
        viewSize,
        outputRect: secondOutput,
        placement: placement,
      ),
      const Rect.fromLTWH(4456, 24, 640, 500),
    );
    expect(
      DesktopMetrics.launcherTriggerRect(
        viewSize,
        outputRect: secondOutput,
        placement: placement,
      ),
      const Rect.fromLTWH(5096, 0, 24, 500),
    );
  });

  test('edge-centered panel triggers match the panel extent', () {
    const topCenter = ShellPopupPlacement(
      anchor: ShellPopupAnchor.topCenter,
      width: 640,
      height: 500,
      margin: 14,
    );
    const bottomCenter = ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomCenter,
      width: 640,
      height: 500,
      margin: 14,
    );

    expect(
      DesktopMetrics.launcherTriggerRect(
        viewSize,
        outputRect: secondOutput,
        placement: topCenter,
      ),
      const Rect.fromLTWH(3520, 0, 640, 14),
    );
    expect(
      DesktopMetrics.dashboardTriggerRect(
        viewSize,
        outputRect: secondOutput,
        placement: bottomCenter,
      ),
      const Rect.fromLTWH(3520, 1426, 640, 14),
    );
  });

  test('maximize without explicit bounds uses the monitor work area', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const workArea = Rect.fromLTRB(0, 32, 2560, 1440);

    controller.syncWindows(
      <DenialWindow>[_window(objectId: 1, windowId: 11, monitorId: 1)],
      viewSize,
      1,
      snapshotSequence: 1,
    );
    controller.syncWorkAreas(const <int, Rect>{1: workArea, 2: secondOutput});
    controller.toggleMaximized(1);

    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      workArea,
    );
  });

  test('maximize and restore targets survive stale native snapshots', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const workArea = Rect.fromLTRB(10, 32, 2550, 1430);
    final original = _window(objectId: 1, windowId: 11, monitorId: 1);

    controller.syncWindows(
      <DenialWindow>[original],
      viewSize,
      1,
      snapshotSequence: 10,
    );
    final restoreFrame = container
        .read(desktopWorkspaceProvider)
        .placements[1]!
        .frame;
    controller.syncWorkAreas(const <int, Rect>{1: workArea});
    controller.toggleMaximized(1);

    controller.syncWindows(
      <DenialWindow>[original],
      viewSize,
      1,
      snapshotSequence: 11,
    );
    var placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.maximized, isTrue);
    expect(placement.frame, workArea);
    expect(placement.restoreFrame, restoreFrame);

    final maximizedNative = _window(
      objectId: 1,
      windowId: 11,
      monitorId: 1,
      geometry: workArea.deflate(DesktopMetrics.frameBorder),
    );
    controller.syncWindows(
      <DenialWindow>[maximizedNative],
      viewSize,
      1,
      snapshotSequence: 12,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      workArea,
    );

    controller.toggleMaximized(1);
    controller.syncWindows(
      <DenialWindow>[maximizedNative],
      viewSize,
      1,
      snapshotSequence: 13,
    );
    placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.maximized, isFalse);
    expect(placement.frame, restoreFrame);
    expect(placement.restoreFrame, isNull);

    controller.syncWindows(
      <DenialWindow>[original],
      viewSize,
      1,
      snapshotSequence: 14,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      restoreFrame,
    );
  });

  test('fullscreen snapshots cannot roll back another pending maximize', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const workArea = Rect.fromLTRB(0, 32, 2560, 1440);
    const fullscreenBounds = Rect.fromLTWH(0, 0, 2560, 1440);
    final maximizedOriginal = _window(
      objectId: 1,
      windowId: 11,
      monitorId: 1,
      geometry: const Rect.fromLTWH(160, 120, 900, 640),
    );
    final fullscreenOriginal = _window(
      objectId: 2,
      windowId: 22,
      monitorId: 1,
      geometry: const Rect.fromLTWH(420, 260, 800, 560),
    );

    controller.syncWindows(
      <DenialWindow>[maximizedOriginal, fullscreenOriginal],
      viewSize,
      1,
      snapshotSequence: 20,
    );
    controller.syncWorkAreas(const <int, Rect>{1: workArea});
    controller.toggleMaximized(1);
    controller.toggleFullscreen(2, bounds: fullscreenBounds);

    // SUPER+F dirties the complete native scene. Both rectangles can still
    // be from the preceding scene while each shell-authored target is in
    // flight; neither window may adopt the other's publication timing.
    controller.syncWindows(
      <DenialWindow>[maximizedOriginal, fullscreenOriginal],
      viewSize,
      1,
      snapshotSequence: 21,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.maximized,
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      workArea,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.fullscreen,
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.frame,
      fullscreenBounds,
    );

    final fullscreenNative = _window(
      objectId: 2,
      windowId: 22,
      monitorId: 1,
      geometry: fullscreenBounds,
    );
    controller.syncWindows(
      <DenialWindow>[maximizedOriginal, fullscreenNative],
      viewSize,
      1,
      snapshotSequence: 22,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.maximized,
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      workArea,
    );
  });

  test('fullscreen round trip returns a maximized window to maximize', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const workArea = Rect.fromLTRB(0, 32, 2560, 1440);
    const fullscreenBounds = Rect.fromLTWH(0, 0, 2560, 1440);
    final original = _window(objectId: 1, windowId: 11, monitorId: 1);

    controller.syncWindows(
      <DenialWindow>[original],
      viewSize,
      1,
      snapshotSequence: 30,
    );
    final restoreFrame = container
        .read(desktopWorkspaceProvider)
        .placements[1]!
        .frame;
    controller.syncWorkAreas(const <int, Rect>{1: workArea});
    controller.toggleMaximized(1);
    final maximizedNative = _window(
      objectId: 1,
      windowId: 11,
      monitorId: 1,
      geometry: workArea.deflate(DesktopMetrics.frameBorder),
    );
    controller.syncWindows(
      <DenialWindow>[maximizedNative],
      viewSize,
      1,
      snapshotSequence: 31,
    );

    controller.toggleFullscreen(1, bounds: fullscreenBounds);
    controller.syncWindows(
      <DenialWindow>[maximizedNative],
      viewSize,
      1,
      snapshotSequence: 32,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.fullscreen,
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      fullscreenBounds,
    );

    final fullscreenNative = _window(
      objectId: 1,
      windowId: 11,
      monitorId: 1,
      geometry: fullscreenBounds,
    );
    controller.syncWindows(
      <DenialWindow>[fullscreenNative],
      viewSize,
      1,
      snapshotSequence: 33,
    );
    controller.toggleFullscreen(1, bounds: fullscreenBounds);
    controller.syncWindows(
      <DenialWindow>[fullscreenNative],
      viewSize,
      1,
      snapshotSequence: 34,
    );

    final placement = container.read(desktopWorkspaceProvider).placements[1]!;
    expect(placement.fullscreen, isFalse);
    expect(placement.maximized, isTrue);
    expect(placement.frame, workArea);
    expect(placement.restoreFrame, restoreFrame);
  });

  test('work area changes re-anchor maximized windows but not fullscreen', () {
    final container = ProviderContainer.test();
    final controller = container.read(desktopWorkspaceProvider.notifier);
    const monitorRect = Rect.fromLTWH(0, 0, 2560, 1440);
    const workArea = Rect.fromLTRB(0, 32, 2560, 1440);

    controller.syncWindows(
      <DenialWindow>[
        _window(objectId: 1, windowId: 11, monitorId: 1),
        _window(objectId: 2, windowId: 22, monitorId: 1),
      ],
      viewSize,
      1,
      snapshotSequence: 1,
    );
    controller.toggleMaximized(1, bounds: monitorRect);
    controller.toggleFullscreen(2, bounds: monitorRect);
    controller.syncWorkAreas(const <int, Rect>{1: workArea});

    expect(
      container.read(desktopWorkspaceProvider).placements[1]!.frame,
      workArea,
    );
    expect(
      container.read(desktopWorkspaceProvider).placements[2]!.frame,
      monitorRect,
    );
  });
}

DenialWindow _window({
  required int objectId,
  required int windowId,
  required int monitorId,
  Rect? geometry,
  String? title,
  bool pinned = false,
  bool serverSideDecorated = true,
}) {
  final nativeGeometry =
      geometry ?? Rect.fromLTWH(monitorId == 2 ? 3520 : 960, 520, 640, 400);
  return DenialWindow(
    objectId: objectId,
    objectKind: 'root_surface',
    surfaceId: objectId,
    windowId: windowId,
    textureId: objectId,
    title: title ?? 'Window $objectId',
    appId: 'test-$objectId',
    width: 2560,
    height: 1440,
    surfaceX: 0,
    surfaceY: 0,
    surfaceWidth: 2560,
    surfaceHeight: 1440,
    textureSourceX: 0,
    textureSourceY: 0,
    textureSourceWidth: 2560,
    textureSourceHeight: 1440,
    geometryX: nativeGeometry.left,
    geometryY: nativeGeometry.top,
    geometryWidth: nativeGeometry.width,
    geometryHeight: nativeGeometry.height,
    monitorId: monitorId,
    transform: 0,
    scale120: 120,
    pinned: pinned,
    serverSideDecorated: serverSideDecorated,
  );
}

DenialWindowPlacementEvent _placementEvent({
  required int sequence,
  required Rect contentRect,
  required int monitorId,
  required int workspaceId,
  DenialWindowPlacementPhase phase = DenialWindowPlacementPhase.end,
  DenialWindowPlacementChange change = DenialWindowPlacementChange.move,
}) {
  return DenialWindowPlacementEvent(
    sequence: sequence,
    windowId: 11,
    contentRect: contentRect,
    monitorId: monitorId,
    workspaceId: workspaceId,
    phase: phase,
    change: change,
  );
}

const _displayLayout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(5120, 1440),
  pixelSize: Size(5120, 1440),
  engineScale: 1,
  tickerMonitorId: 1,
  systemBarMonitorId: 1,
  systemBarSide: SystemBarSide.hidden,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 1,
      name: 'left',
      logicalRect: Rect.fromLTWH(0, 0, 2560, 1440),
      pixelSize: Size(2560, 1440),
      scale: 1,
      refreshRate: 60,
    ),
    DisplayOutput(
      monitorId: 2,
      name: 'right',
      logicalRect: Rect.fromLTWH(2560, 0, 2560, 1440),
      pixelSize: Size(2560, 1440),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);
