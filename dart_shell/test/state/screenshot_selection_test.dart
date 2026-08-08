import 'dart:ui';

import 'package:denial_dart_shell/src/state/screenshot_selection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selection normalizes reverse drags and rejects accidental clicks', () {
    final container = ProviderContainer.test();
    final controller = container.read(screenshotSelectionProvider.notifier);

    expect(controller.prepare(41), isTrue);
    expect(controller.textureReady(41, 9001), isTrue);
    controller.start(const Offset(320, 240));
    controller.update(const Offset(20, 40));
    expect(controller.complete(), const Rect.fromLTWH(20, 40, 300, 200));

    controller.start(const Offset(10, 10));
    controller.update(const Offset(11, 80));
    expect(controller.complete(), isNull);
    expect(container.read(screenshotSelectionProvider)?.selection, isNull);

    controller.finishLocally(41);
    controller.done(41);
    expect(container.read(screenshotSelectionProvider), isNull);
  });

  test('lifecycle rejects stale messages and waits for native done', () {
    final container = ProviderContainer.test();
    final controller = container.read(screenshotSelectionProvider.notifier);

    expect(controller.prepare(7), isTrue);
    expect(controller.prepare(8), isFalse);
    expect(container.read(screenshotSelectionProvider)!.hidesCursor, isTrue);
    expect(controller.textureReady(8, 101), isFalse);
    expect(controller.textureReady(7, 101), isTrue);

    final selecting = container.read(screenshotSelectionProvider)!;
    expect(selecting.phase, ScreenshotSelectionPhase.selecting);
    expect(selecting.textureId, 101);
    expect(selecting.hidesCursor, isFalse);

    controller.finishLocally(7);
    expect(
      container.read(screenshotSelectionProvider)!.phase,
      ScreenshotSelectionPhase.finishing,
    );
    controller.done(8);
    expect(container.read(screenshotSelectionProvider), isNotNull);
    controller.done(7);
    expect(container.read(screenshotSelectionProvider), isNull);
  });
}
