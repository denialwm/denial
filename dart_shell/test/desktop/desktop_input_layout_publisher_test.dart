import 'package:denial_dart_shell/src/desktop/desktop_input_layout_publisher.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('position-only geometry changes are published to Rust', () {
    final tracker = DesktopWindowConfigureTracker();

    expect(
      tracker.update(
        1,
        const Rect.fromLTWH(100, 80, 800, 600),
        nativeDragActive: false,
      ),
      isNull,
      reason: 'the first native rectangle seeds the cache',
    );
    expect(
      tracker.update(
        1,
        const Rect.fromLTWH(10, 32, 800, 600),
        nativeDragActive: false,
      ),
      const Rect.fromLTWH(10, 32, 800, 600),
    );
  });

  test('native drag geometry is learned without being echoed', () {
    final tracker = DesktopWindowConfigureTracker();
    tracker.update(
      1,
      const Rect.fromLTWH(100, 80, 800, 600),
      nativeDragActive: false,
    );

    expect(
      tracker.update(
        1,
        const Rect.fromLTWH(240, 180, 800, 600),
        nativeDragActive: true,
      ),
      isNull,
    );
    expect(
      tracker.update(
        1,
        const Rect.fromLTWH(240, 180, 800, 600),
        nativeDragActive: false,
      ),
      isNull,
      reason: 'ending the drag must not echo its final native rectangle',
    );
  });
}
