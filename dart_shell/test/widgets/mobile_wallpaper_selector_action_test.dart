import 'dart:async';

import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/mobile_wallpaper_selector_layer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final hasLayout in [true, false]) {
    testWidgets(
      'wallpaper action opens mobile selector with layout=$hasLayout',
      (tester) async {
        final harness = _Harness(
          layout: hasLayout
              ? DisplayLayout.fallback(const Size(500, 900), 3)
              : null,
        );
        addTearDown(harness.dispose);
        await tester.pumpWidget(harness.widget);
        harness.send(DenialShellAction.dashboard);
        await tester.pump();
        expect(harness.wallpaper.opened, isEmpty);
        harness.send(DenialShellAction.wallpaper);
        await tester.pump();
        expect(harness.wallpaper.opened, [
          hasLayout ? const Size(1500, 2700) : const Size(800, 1600),
        ]);
        harness.shell.setLocked(true);
        harness.send(DenialShellAction.wallpaper);
        await tester.pump();
        expect(harness.wallpaper.opened, hasLength(1));
        await tester.pumpWidget(const SizedBox());
        harness.send(DenialShellAction.wallpaper);
        await tester.pump();
        expect(harness.wallpaper.opened, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final unmount in [false, true]) {
    testWidgets(
      'pending wallpaper request is discarded after ${unmount ? 'unmount' : 'lock'}',
      (tester) async {
        final pending = Completer<DisplayLayout?>();
        final harness = _Harness(pending: pending.future);
        addTearDown(harness.dispose);
        await tester.pumpWidget(harness.widget);
        harness.send(DenialShellAction.wallpaper);
        await tester.pump();
        expect(harness.wallpaper.opened, isEmpty);
        if (unmount) {
          await tester.pumpWidget(const SizedBox());
        } else {
          harness.shell.setLocked(true);
        }
        pending.complete(DisplayLayout.fallback(const Size(500, 900), 3));
        await tester.pump();
        expect(harness.wallpaper.opened, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

class _Harness {
  _Harness({DisplayLayout? layout, Future<DisplayLayout?>? pending}) {
    container = ProviderContainer.test(
      overrides: [
        denialBridgeProvider.overrideWithValue(bridge),
        shellControllerProvider.overrideWith(() => shell),
        wallpaperControllerProvider.overrideWith(() => wallpaper),
        displayLayoutProvider.overrideWith(() => _Displays(layout, pending)),
      ],
    );
  }
  final bridge = _Bridge();
  final shell = _Shell();
  final wallpaper = _Wallpaper();
  late final ProviderContainer container;

  void send(DenialShellAction action) => bridge.actions.add(
    DenialShellActionEvent(
      action: action,
      monitorId: null,
      requestId: 0,
      textureId: null,
      workspaceId: null,
    ),
  );

  Widget get widget => UncontrolledProviderScope(
    container: container,
    child: const Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(400, 800),
          devicePixelRatio: 2,
          disableAnimations: true,
        ),
        child: MobileWallpaperSelectorLayer(),
      ),
    ),
  );

  Future<void> dispose() async {
    container.dispose();
    await bridge.actions.close();
    bridge.dispose();
  }
}

class _Bridge extends DenialBridge {
  final actions = StreamController<DenialShellActionEvent>.broadcast(
    sync: true,
  );
  @override
  Stream<DenialShellActionEvent> get shellActions => actions.stream;
}

class _Shell extends ShellController {
  @override
  ShellState build() => ShellState.initial(locked: false);
  void setLocked(bool value) => state = ShellState.initial(locked: value);
}

class _Displays extends DisplayLayoutController {
  _Displays(this.layout, this.pending);
  final DisplayLayout? layout;
  final Future<DisplayLayout?>? pending;
  @override
  DisplayLayout? build() => layout;
  @override
  Future<DisplayLayout?> ensureLoaded() => pending ?? Future.value(layout);
}

class _Wallpaper extends WallpaperController {
  final opened = <Size>[];
  @override
  WallpaperExperienceState build() => WallpaperExperienceState.initial();
  @override
  void openSelector({required Size targetPixelSize}) =>
      opened.add(targetPixelSize);
}
