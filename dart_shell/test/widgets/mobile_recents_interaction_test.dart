import 'package:denial_dart_shell/src/features/mobile/mobile_window_layers.dart';
import 'package:denial_dart_shell/src/features/mobile/mobile_launcher_layer.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/home_surface.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/launcher/models/home_clock_info.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/launcher/widgets/home_app_page.dart';
import 'package:denial_dart_shell/src/launcher/widgets/home_backdrop.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_snapshot.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/lock_state_repository.dart';
import 'package:denial_dart_shell/src/state/authentication.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_profile.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/widgets/bottom_gesture_handle.dart';
import 'package:denial_dart_shell/src/widgets/gesture_pill.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_focus_overlay.dart';
import 'package:denial_dart_shell/src/widgets/overview/overview_window_preview.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mobile_motion_harness.dart';

void main() {
  testWidgets(
    'home content follows recents progress without rebuilding grids',
    (tester) async {
      final harness = await _pumpShell(tester, includeLauncher: true);
      await tester.pumpAndSettle();
      final home = find.byType(HomeSurface);
      final page = find.byType(HomeAppPage).first;
      expect(_homeOpacity(tester), 1);
      harness.controller.updateGestureDrag(const Offset(0, -24));
      await tester.pump();
      expect(_homeOpacity(tester), inExclusiveRange(0, 1));
      expect(tester.widget<HomeSurface>(home).active, isTrue);
      expect(tester.widget<HomeSurface>(home).interactive, isFalse);
      final retainedPage = tester.widget(page);
      final retainedHome = home.evaluate().single;
      final builds = <String>[];
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, _) =>
          builds.add(element.widget.runtimeType.toString());
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      var opacity = _homeOpacity(tester);
      for (var frame = 0; frame < 30; frame++) {
        harness.controller.updateGestureDrag(const Offset(0, -4));
        await tester.pump();
        final next = _homeOpacity(tester);
        expect(next, lessThan(opacity));
        expect(tester.widget(page), same(retainedPage));
        expect(home.evaluate().single, same(retainedHome));
        opacity = next;
      }
      expect(builds.where((name) => name.contains('Home')), isEmpty);
      debugOnRebuildDirtyWidget = previous;
      // The wallpaper scrim is a sibling of the fade, not part of its contents.
      final backdrop = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is HomeBackdropPainter,
      );
      expect(
        find.ancestor(of: backdrop, matching: find.byType(FadeTransition)),
        findsNothing,
      );
      harness.controller.openOverview();
      await tester.pump();
      expect(_homeOpacity(tester), closeTo(opacity, 0.001));
      await tester.pumpAndSettle();
      expect(_homeOpacity(tester), 0);
      expect(tester.widget<HomeSurface>(home).interactive, isFalse);
      harness.controller.closeOverview();
      await tester.pump();
      expect(_homeOpacity(tester), 0);
      expect(tester.widget<HomeSurface>(home).interactive, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_homeOpacity(tester), inExclusiveRange(0, 1));
      expect(tester.widget<HomeSurface>(home).interactive, isFalse);
      await tester.pumpAndSettle();
      expect(_homeOpacity(tester), 1);
      expect(tester.widget<HomeSurface>(home).interactive, isTrue);
      expect(home.evaluate().single, same(retainedHome));
    },
  );

  testWidgets(
    'cancelling and reversing recents keeps the home fade continuous',
    (tester) async {
      final harness = await _pumpShell(tester, includeLauncher: true);
      await tester.pumpAndSettle();
      harness.controller.updateGestureDrag(const Offset(0, -100));
      await tester.pump();
      final dragging = _homeOpacity(tester);
      harness.controller.resetGestureDrag();
      await tester.pump();
      expect(_homeOpacity(tester), dragging);
      await tester.pump(const Duration(milliseconds: 50));
      final returning = _homeOpacity(tester);
      expect(returning, greaterThan(dragging));
      expect(returning, lessThan(1));
      harness.controller.openOverview();
      await tester.pump();
      expect(_homeOpacity(tester), returning);
      await tester.pumpAndSettle();
      expect(_homeOpacity(tester), 0);
      harness.controller.closeOverview();
      await tester.pumpAndSettle();
      expect(_homeOpacity(tester), 1);
    },
  );

  testWidgets('closing recents entered from an app fades home back in', (
    tester,
  ) async {
    final harness = await _pumpShell(tester, includeLauncher: true);
    harness.controller.focusWindow(harness.bridge.windows.last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<HomeSurface>(find.byType(HomeSurface)).active,
      isFalse,
    );
    harness.controller.openOverview();
    await tester.pumpAndSettle();
    expect(_homeOpacity(tester), 0);
    harness.controller.closeOverview();
    await tester.pump();
    expect(tester.widget<HomeSurface>(find.byType(HomeSurface)).active, isTrue);
    expect(_homeOpacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_homeOpacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_homeOpacity(tester), 1);
  });

  for (final activationFirst in [true, false]) {
    testWidgets('dismiss stays in recents when native activation arrives '
        '${activationFirst ? 'before' : 'after'} the removal snapshot', (
      tester,
    ) async {
      final harness = await _pumpShell(tester);
      harness.controller.focusWindow(harness.bridge.windows.last);
      harness.controller.openOverview();
      await tester.pumpAndSettle();
      harness.bridge.focused.clear();
      final neighborBefore = tester.getRect(_preview(2));

      await tester.fling(_preview(3), const Offset(0, -100), 1600);
      for (
        var frame = 0;
        harness.bridge.closed.isEmpty && frame < 100;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(harness.bridge.closed, [3]);
      if (activationFirst) harness.bridge.activate(2);
      harness.bridge.remove(3);
      if (!activationFirst) harness.bridge.activate(2);
      await tester.pump();
      expect(harness.state.overviewVisible, isTrue);
      expect(harness.state.foregroundObjectId, isNull);
      expect(harness.bridge.focused, isEmpty);
      expect(find.byType(OverviewFocusOverlay), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      final during = tester.getRect(_preview(2));
      expect(during.size, neighborBefore.size);
      expect(during.center.dx, greaterThan(neighborBefore.center.dx));
      expect(during.center.dx, lessThan(200));
      await tester.pumpAndSettle();
      expect(harness.state.overviewVisible, isTrue);
      expect(_preview(3), findsNothing);
      expect(tester.getCenter(_preview(2)).dx, closeTo(200, 0.01));

      // Only an explicit card selection leaves recents and focuses an app.
      await tester.tap(_preview(2));
      await tester.pumpAndSettle();
      expect(harness.state.overviewVisible, isFalse);
      expect(harness.state.foregroundObjectId, 2);
      expect(harness.bridge.focused, [2]);
      harness.bridge.activate(1);
      expect(harness.state.foregroundObjectId, 1);
    });
  }

  testWidgets('closing the final recent app returns home', (tester) async {
    final harness = await _pumpShell(tester, appCount: 1);
    harness.controller.focusWindow(harness.bridge.windows.single);
    harness.controller.openOverview();
    await tester.pumpAndSettle();
    await tester.fling(_preview(1), const Offset(0, -100), 1600);
    await tester.pumpAndSettle();
    expect(harness.bridge.closed, [1]);
    expect(harness.state.overviewVisible, isFalse);
    expect(harness.state.foregroundObjectId, isNull);
  });

  for (final appCount in [0, 3]) {
    testWidgets('a short home flick opens recents with $appCount apps', (
      tester,
    ) async {
      final harness = await _pumpShell(tester, appCount: appCount);
      expect(harness.state.foregroundObjectId, isNull);
      // 85 pixels is below the 128-pixel long-pull threshold on this screen.
      await tester.fling(find.byType(GesturePill), const Offset(0, -85), 1800);
      await tester.pumpAndSettle();
      expect(harness.state.overviewVisible, isTrue);
      expect(harness.state.homeTransitionActive, isFalse);
      expect(harness.state.gestureDrag, Offset.zero);
      expect(harness.bridge.focused, isEmpty);
    });
  }

  testWidgets('the same short flick still sends the foreground app home', (
    tester,
  ) async {
    final harness = await _pumpShell(tester);
    harness.controller.focusWindow(harness.bridge.windows.last);
    await tester.pump();
    await tester.fling(find.byType(GesturePill), const Offset(0, -85), 1800);
    await tester.pumpAndSettle();
    expect(harness.state.foregroundObjectId, isNull);
    expect(harness.state.overviewVisible, isFalse);
    expect(harness.state.homeTransitionActive, isFalse);
  });

  testWidgets('cancelling an upward home drag leaves recents closed', (
    tester,
  ) async {
    final harness = await _pumpShell(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(GesturePill)),
    );
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(harness.state.overviewVisible, isFalse);
    expect(harness.state.gestureDrag, Offset.zero);
    expect(harness.bridge.focused, isEmpty);
  });
}

Finder _preview(int id) => find.byWidgetPredicate(
  (widget) => widget is OverviewWindowPreview && widget.window.objectId == id,
);

double _homeOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .descendant(
            of: find.byType(HomeSurface),
            matching: find.byType(FadeTransition, skipOffstage: false),
            skipOffstage: false,
          )
          .first,
    )
    .opacity
    .value;

Future<_ShellHarness> _pumpShell(
  WidgetTester tester, {
  int appCount = 3,
  bool includeLauncher = false,
}) async {
  final resampling = tester.binding.resamplingEnabled;
  tester.binding.resamplingEnabled = false;
  addTearDown(() => tester.binding.resamplingEnabled = resampling);
  final size = includeLauncher ? const Size(600, 1000) : const Size(400, 800);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final bridge = _RecentsBridge([
    for (var id = 1; id <= appCount; id++) motionWindow(id),
  ]);
  addTearDown(bridge.dispose);
  final container = ProviderContainer.test(
    overrides: [
      denialBridgeProvider.overrideWithValue(bridge),
      lockStateRepositoryProvider.overrideWithValue(_NoLockFiles()),
      authenticationProvider.overrideWith(_NoAuthentication.new),
      shellProfileProvider.overrideWithValue(ShellProfile.mobile),
      if (includeLauncher)
        homeGridControllerProvider.overrideWith(_RecentsGrid.new),
      if (includeLauncher)
        homeClockProvider.overrideWithValue(
          HomeClockInfo(
            now: DateTime(2026, 9, 8, 12),
            locale: 'en',
            power: HomePowerStatus.unknown,
          ),
        ),
    ],
  );
  final progress = ValueNotifier(0.0);
  final presented = ValueNotifier(false);
  addTearDown(progress.dispose);
  addTearDown(presented.dispose);
  final opacity = Animation<double>.fromValueListenable(
    progress,
    transformer: (value) => 1 - value,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: mobileMotionHarness(
        Stack(
          children: [
            if (includeLauncher)
              MobileLauncherLayer(
                contentOpacity: opacity,
                overviewPresentationActive: presented,
              ),
            MobileOverviewLayer(
              onPresentationChanged: (value) => presented.value = value,
              onProgressChanged: (value) => progress.value = value,
            ),
            const BottomGestureHandle(),
          ],
        ),
        size: size,
      ),
    ),
  );
  await tester.pump();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  return _ShellHarness(container, bridge);
}

class _ShellHarness {
  _ShellHarness(this.container, this.bridge);
  final ProviderContainer container;
  final _RecentsBridge bridge;
  ShellController get controller =>
      container.read(shellControllerProvider.notifier);
  ShellState get state => container.read(shellControllerProvider);
}

class _RecentsBridge extends DenialBridge {
  _RecentsBridge(this.windows);
  List<DenialWindow> windows;
  final closed = <int>[];
  final focused = <int>[];
  int sequence = 1;
  late ValueChanged<int> activate;
  late ValueChanged<DenialWindowSnapshot> snapshot;

  @override
  void start({
    required VoidCallback onWindowsChanged,
    ValueChanged<DenialWindowSnapshot>? onWindowSnapshot,
    required ValueChanged<int> onWindowActivated,
  }) {
    activate = onWindowActivated;
    snapshot = onWindowSnapshot!;
  }

  @override
  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) async =>
      DenialWindowSnapshot(sequence: sequence, windows: windows);

  @override
  void closeWindow(DenialWindow window) => closed.add(window.objectId);

  @override
  void focusWindow(DenialWindow window) => focused.add(window.objectId);

  void remove(int id) {
    windows = windows.where((window) => window.objectId != id).toList();
    snapshot(DenialWindowSnapshot(sequence: ++sequence, windows: windows));
  }
}

class _NoAuthentication extends AuthenticationController {
  @override
  AuthenticationState build() => const AuthenticationState.initial();
}

class _NoLockFiles extends LockStateRepository {
  @override
  void start({required LockRequestChanged onChanged}) {}
}

class _RecentsGrid extends HomeGridController {
  @override
  Future<HomeGridState> build() async => HomeGridState(
    slots: [
      HomeGridItem.clock(),
      null,
      for (var id = 0; id < 50; id++)
        HomeGridItem.app(
          DesktopApp(
            id: '$id',
            name: 'App $id',
            exec: 'unused',
            desktopPath: 'unused',
            categories: const [],
          ),
        ),
    ],
  );

  @override
  void setLauncherActive(bool active) {}
}
