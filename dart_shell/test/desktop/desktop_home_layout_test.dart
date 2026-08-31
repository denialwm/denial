import 'package:denial_dart_shell/src/desktop/desktop_home_layout.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopHomeLayout.offscreenFrame', () {
    const bounds = Rect.fromLTWH(0, 0, 1920, 1080);

    test('moves a lower window beyond the bottom edge', () {
      const source = Rect.fromLTWH(700, 680, 520, 320);

      final target = DesktopHomeLayout.offscreenFrame(
        bounds: bounds,
        source: source,
      );

      expect(target.size, source.size);
      expect(target.top, greaterThan(bounds.bottom));
      expect(target.overlaps(bounds), isFalse);
    });

    test('always exits below without changing horizontal position', () {
      const source = Rect.fromLTWH(12, 360, 640, 480);

      final target = DesktopHomeLayout.offscreenFrame(
        bounds: bounds,
        source: source,
      );

      expect(target.size, source.size);
      expect(target.left, source.left);
      expect(target.top, greaterThan(bounds.bottom));
      expect(target.overlaps(bounds), isFalse);
    });

    test('keeps empty geometry unchanged', () {
      expect(
        DesktopHomeLayout.offscreenFrame(bounds: bounds, source: Rect.zero),
        Rect.zero,
      );
    });
  });
}
