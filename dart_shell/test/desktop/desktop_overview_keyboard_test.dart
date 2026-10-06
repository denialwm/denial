import 'package:denial_dart_shell/src/desktop/desktop_overview_keyboard.dart';
import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overview navigation follows rows and columns', () {
    final frames = <int, Rect>{
      1: const Rect.fromLTWH(0, 0, 100, 80),
      2: const Rect.fromLTWH(120, 0, 100, 80),
      3: const Rect.fromLTWH(0, 100, 100, 80),
      4: const Rect.fromLTWH(120, 100, 100, 80),
    };

    expect(
      desktopOverviewNeighbor(
        frames: frames,
        fromObjectId: 1,
        direction: DesktopOverviewDirection.right,
      ),
      2,
    );
    expect(
      desktopOverviewNeighbor(
        frames: frames,
        fromObjectId: 1,
        direction: DesktopOverviewDirection.down,
      ),
      3,
    );
    expect(
      desktopOverviewNeighbor(
        frames: frames,
        fromObjectId: 4,
        direction: DesktopOverviewDirection.left,
      ),
      3,
    );
    expect(
      desktopOverviewNeighbor(
        frames: frames,
        fromObjectId: 1,
        direction: DesktopOverviewDirection.up,
      ),
      isNull,
    );
  });

  test('workspace overview starts selected and moves selection', () {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    workspace.syncWindows(
      <DenialWindow>[
        _window(1, const Rect.fromLTWH(20, 20, 420, 300)),
        _window(2, const Rect.fromLTWH(500, 20, 420, 300)),
      ],
      const Size(1000, 700),
      1,
      snapshotSequence: 1,
    );
    workspace.toggleOverview(
      monitorId: 1,
      bounds: const Rect.fromLTWH(0, 0, 1000, 700),
      backgroundBounds: const Rect.fromLTWH(0, 0, 1000, 700),
      selectedObjectId: 1,
    );

    expect(
      container.read(desktopWorkspaceProvider).overview?.selectedObjectId,
      1,
    );
    expect(
      workspace.moveOverviewSelection(DesktopOverviewDirection.right),
      isTrue,
    );
    expect(
      container.read(desktopWorkspaceProvider).overview?.selectedObjectId,
      2,
    );
  });

  testWidgets('arrows navigate and Enter, Space, and Escape act', (
    tester,
  ) async {
    final directions = <DesktopOverviewDirection>[];
    var activations = 0;
    var dismissals = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DesktopOverviewKeyboard(
          active: true,
          onNavigate: directions.add,
          onActivate: () => activations += 1,
          onDismiss: () => dismissals += 1,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    expect(directions, <DesktopOverviewDirection>[
      DesktopOverviewDirection.right,
    ]);
    expect(activations, 2);
    expect(dismissals, 1);
  });
}

DenialWindow _window(int id, Rect geometry) => DenialWindow(
  objectId: id,
  objectKind: 'xdg',
  surfaceId: id + 10,
  windowId: id + 20,
  textureId: id + 30,
  title: 'Window $id',
  appId: 'test.app.$id',
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
  transform: 0,
  scale120: 120,
);
