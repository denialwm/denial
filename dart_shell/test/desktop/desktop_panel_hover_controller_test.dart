import 'package:denial_dart_shell/src/desktop/desktop_panel_hover_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defers a pending close until the panel has finished opening', () {
    fakeAsync((async) {
      var closes = 0;
      final controller = DesktopPanelHoverController(
        onClose: () => closes += 1,
      );

      controller.beginOpening();
      controller.scheduleClose();
      async.elapse(const Duration(seconds: 1));
      expect(closes, 0);

      controller.openingCompleted();
      async.elapse(const Duration(milliseconds: 219));
      expect(closes, 0);
      async.elapse(const Duration(milliseconds: 1));
      expect(closes, 1);

      controller.dispose();
    });
  });

  test('uses the ordinary close delay after opening', () {
    fakeAsync((async) {
      var closes = 0;
      final controller = DesktopPanelHoverController(
        onClose: () => closes += 1,
      );

      controller.beginOpening();
      controller.openingCompleted();
      controller.scheduleClose();
      async.elapse(const Duration(milliseconds: 219));
      expect(closes, 0);
      async.elapse(const Duration(milliseconds: 1));
      expect(closes, 1);

      controller.dispose();
    });
  });

  test('entering the panel cancels a close queued during opening', () {
    fakeAsync((async) {
      var closes = 0;
      final controller = DesktopPanelHoverController(
        onClose: () => closes += 1,
      );

      controller.beginOpening();
      controller.scheduleClose();
      controller.cancelClose();
      controller.openingCompleted();
      async.elapse(const Duration(seconds: 1));
      expect(closes, 0);

      controller.dispose();
    });
  });
}
