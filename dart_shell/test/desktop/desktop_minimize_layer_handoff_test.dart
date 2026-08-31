import 'package:denial_dart_shell/src/desktop/desktop_minimize_layer_handoff.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps a minimizing window foreground until motion nearly finishes', () {
    fakeAsync((async) {
      var handoffs = 0;
      final controller = DesktopMinimizeLayerHandoffController(
        handoffDelay: Motion.desktopWindowLayerHandoff,
        desktopEntryDuration: Motion.desktopWindowWidgetEnter,
        onChanged: () => handoffs += 1,
      );

      controller.begin(42, animate: true);
      expect(controller.keepsOnForeground(42), isTrue);

      async.elapse(
        Motion.desktopWindowLayerHandoff - const Duration(milliseconds: 1),
      );
      expect(controller.keepsOnForeground(42), isTrue);
      expect(handoffs, 0);

      async.elapse(const Duration(milliseconds: 1));
      expect(controller.keepsOnForeground(42), isFalse);
      expect(controller.slidesIntoDesktop(42), isTrue);
      expect(handoffs, 1);

      async.elapse(Motion.desktopWindowWidgetEnter);
      expect(controller.keepsOnForeground(42), isFalse);
      expect(controller.slidesIntoDesktop(42), isFalse);
      expect(handoffs, 2);
    });
  });

  test('restore cancels the pending layer handoff', () {
    fakeAsync((async) {
      var handoffs = 0;
      final controller = DesktopMinimizeLayerHandoffController(
        handoffDelay: Motion.desktopWindowLayerHandoff,
        desktopEntryDuration: Motion.desktopWindowWidgetEnter,
        onChanged: () => handoffs += 1,
      );

      controller.begin(7, animate: true);
      controller.cancel(7);
      async.elapse(Motion.desktopWindowWidget);

      expect(controller.keepsOnForeground(7), isFalse);
      expect(handoffs, 0);
    });
  });

  test('reduced motion hands off without a delay', () {
    fakeAsync((async) {
      var handoffs = 0;
      final controller = DesktopMinimizeLayerHandoffController(
        handoffDelay: Motion.desktopWindowLayerHandoff,
        desktopEntryDuration: Motion.desktopWindowWidgetEnter,
        onChanged: () => handoffs += 1,
      );

      controller.begin(9, animate: false);

      expect(controller.keepsOnForeground(9), isFalse);
      expect(handoffs, 0);
    });
  });

  test('desktop placement exits upward before committing off-screen', () {
    fakeAsync((async) {
      var changes = 0;
      final controller = DesktopMinimizedPlacementTransitionController(
        duration: Motion.desktopWindowPlacementTransition,
        onChanged: () => changes += 1,
      );

      controller.begin(<int>[3, 4], toDesktop: false, animate: true);

      expect(
        controller.usesDesktopPlacement(3, configuredDesktop: false),
        isTrue,
      );
      expect(controller.exitsDesktop(3), isTrue);
      expect(controller.commitsOffscreen(3), isFalse);

      async.elapse(Motion.desktopWindowPlacementTransition);

      expect(
        controller.usesDesktopPlacement(3, configuredDesktop: false),
        isFalse,
      );
      expect(controller.exitsDesktop(3), isFalse);
      expect(controller.commitsOffscreen(3), isTrue);
      expect(changes, 1);
    });
  });

  test('off-screen placement enters the desktop from above', () {
    fakeAsync((async) {
      var changes = 0;
      final controller = DesktopMinimizedPlacementTransitionController(
        duration: Motion.desktopWindowPlacementTransition,
        onChanged: () => changes += 1,
      );

      controller.begin(<int>[8], toDesktop: true, animate: true);

      expect(
        controller.usesDesktopPlacement(8, configuredDesktop: true),
        isTrue,
      );
      expect(controller.entersDesktop(8), isTrue);

      async.elapse(Motion.desktopWindowPlacementTransition);

      expect(controller.entersDesktop(8), isFalse);
      expect(
        controller.usesDesktopPlacement(8, configuredDesktop: true),
        isTrue,
      );
      expect(changes, 1);
    });
  });

  test('reduced motion changes minimized placement immediately', () {
    fakeAsync((async) {
      var changes = 0;
      final controller = DesktopMinimizedPlacementTransitionController(
        duration: Motion.desktopWindowPlacementTransition,
        onChanged: () => changes += 1,
      );

      controller.begin(<int>[12], toDesktop: false, animate: false);

      expect(
        controller.usesDesktopPlacement(12, configuredDesktop: false),
        isFalse,
      );
      expect(controller.exitsDesktop(12), isFalse);
      expect(changes, 0);
    });
  });
}
