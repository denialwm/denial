import 'package:denial_dart_shell/src/desktop/desktop_overview_preview_interaction.dart';
import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/desktop/retained_animated_positioned.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('middle click closes the hovered overview preview', (
    tester,
  ) async {
    var activations = 0;
    var closes = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 240,
            height: 160,
            child: DesktopOverviewPreviewInteraction(
              overviewActive: true,
              overview: true,
              desktopWidget: false,
              dragging: false,
              label: 'Window preview',
              onTap: () => activations += 1,
              onClose: () => closes += 1,
              onDragStart: () {},
              onDragUpdate: (_) {},
              onDragEnd: () {},
              onDragCancel: () {},
              child: const ColoredBox(color: Color(0xff000000)),
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    addTearDown(mouse.removePointer);
    final preview = find.byType(DesktopOverviewPreviewInteraction);
    final center = tester.getCenter(preview);
    await mouse.addPointer(location: center);
    await tester.pump();
    await mouse.down(center);
    await tester.pump();
    await mouse.up();

    expect(closes, 1);
    expect(activations, 0);
  });

  testWidgets('overview emphasis waits for the position animation', (
    tester,
  ) async {
    final transitionCompleted = ValueNotifier<bool>(false);
    addTearDown(transitionCompleted.dispose);

    Widget scene({required bool selected}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: DesktopOverviewTransitionStatus(
          completed: transitionCompleted,
          child: Center(
            child: SizedBox(
              width: 240,
              height: 160,
              child: DesktopOverviewPreviewInteraction(
                overviewActive: true,
                overview: true,
                desktopWidget: false,
                dragging: false,
                selected: selected,
                label: 'Window preview',
                onTap: () {},
                onClose: () {},
                onDragStart: () {},
                onDragUpdate: (_) {},
                onDragEnd: () {},
                onDragCancel: () {},
                child: const ColoredBox(color: Color(0xff000000)),
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(selected: true));
    final preview = find.byType(DesktopOverviewPreviewInteraction);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(preview));
    await tester.pumpAndSettle();

    var scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1.0);

    transitionCompleted.value = true;
    await tester.pump();
    scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1.018);

    await tester.pumpWidget(scene(selected: false));
    scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1.018);
    final highlight = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final border = (highlight.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 0.0);
  });

  testWidgets('resized retained preview taps at its overview rectangle', (
    tester,
  ) async {
    var activations = 0;
    const desktopRect = Rect.fromLTWH(820, 500, 320, 240);
    const overviewRect = Rect.fromLTWH(60, 40, 176, 132);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 1200,
          height: 800,
          child: Stack(
            children: [
              RetainedAnimatedPositioned(
                rect: overviewRect,
                layoutRect: desktopRect,
                globalClipRect: const Rect.fromLTWH(0, 0, 1200, 800),
                duration: Duration.zero,
                child: DesktopOverviewPreviewInteraction(
                  overviewActive: true,
                  overview: true,
                  desktopWidget: false,
                  dragging: false,
                  label: 'Resized window preview',
                  onTap: () => activations += 1,
                  onClose: () {},
                  onDragStart: () {},
                  onDragUpdate: (_) {},
                  onDragEnd: () {},
                  onDragCancel: () {},
                  child: const ColoredBox(color: Color(0xff000000)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tapAt(overviewRect.center);
    expect(activations, 1);
  });

  testWidgets('surviving previews animate to the recomputed overview frames', (
    tester,
  ) async {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final workspace = container.read(desktopWorkspaceProvider.notifier);
    final windows = <DenialWindow>[
      _window(1, const Rect.fromLTWH(20, 20, 420, 300)),
      _window(2, const Rect.fromLTWH(450, 30, 360, 300)),
      _window(3, const Rect.fromLTWH(820, 40, 340, 300)),
    ];
    workspace.syncWindows(
      windows,
      const Size(1200, 800),
      1,
      snapshotSequence: 1,
    );
    workspace.toggleOverview(
      monitorId: 1,
      bounds: const Rect.fromLTWH(0, 0, 1200, 800),
      backgroundBounds: const Rect.fromLTWH(0, 0, 1200, 800),
    );
    final beforeFrames = container
        .read(desktopWorkspaceProvider)
        .overview!
        .frames;

    workspace.syncWindows(
      <DenialWindow>[windows[0], windows[2]],
      const Size(1200, 800),
      1,
      snapshotSequence: 2,
    );
    final state = container.read(desktopWorkspaceProvider);
    expect(state.overviewActive, isTrue);
    expect(state.overview!.frames.keys, unorderedEquals(<int>[1, 3]));
    final objectId = <int>[
      1,
      3,
    ].firstWhere((id) => beforeFrames[id] != state.overview!.frames[id]);
    final before = beforeFrames[objectId]!;
    final after = state.overview!.frames[objectId]!;
    const previewKey = ValueKey<String>('surviving-preview');

    Widget scene(Rect frame) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 1200,
          height: 800,
          child: Stack(
            children: [
              RetainedAnimatedPositioned(
                key: ValueKey<int>(objectId),
                rect: frame,
                duration: const Duration(milliseconds: 300),
                curve: Curves.linear,
                child: const ColoredBox(
                  key: previewKey,
                  color: Color(0xff000000),
                ),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(before));
    expect(tester.getRect(find.byKey(previewKey)), before);

    await tester.pumpWidget(scene(after));
    expect(tester.getRect(find.byKey(previewKey)), before);
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.getRect(find.byKey(previewKey)),
      Rect.lerp(before, after, 0.5),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getRect(find.byKey(previewKey)), after);
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
