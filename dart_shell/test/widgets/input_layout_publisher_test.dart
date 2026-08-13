import 'package:denial_dart_shell/src/input/input_layout.dart';
import 'package:denial_dart_shell/src/widgets/input_layout_publisher.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile windows receive the exact application viewport once', () {
    final tracker = MobileWindowConfigureTracker();

    expect(
      tracker.update(41, const Size(632, 1390), reserveStatusBar: true),
      const Rect.fromLTWH(0, 48, 632, 1342),
    );
    expect(
      tracker.update(41, const Size(632, 1390), reserveStatusBar: true),
      isNull,
    );
  });

  test('mobile viewport changes replace the retained exact geometry', () {
    final tracker = MobileWindowConfigureTracker();
    tracker.update(41, const Size(632, 1390), reserveStatusBar: true);

    expect(
      tracker.update(41, const Size(1390, 632), reserveStatusBar: true),
      const Rect.fromLTWH(0, 48, 1390, 584),
    );
    tracker.retainWindowIds(const <int>{});
    expect(
      tracker.update(41, const Size(1390, 632), reserveStatusBar: true),
      const Rect.fromLTWH(0, 48, 1390, 584),
    );
  });

  test('open keyboard preserves both its panel and right scroll strip', () {
    final regions = ShellMetrics.softwareKeyboardRegions(
      const Size(420, 840),
      progress: 1,
      scrollStripVisible: true,
    );

    expect(regions, hasLength(2));
    expect(regions.first, ShellMetrics.edgePanelRect(const Size(420, 840), 1));
    expect(
      regions.last,
      ShellMetrics.edgePanelScrollStripRect(const Size(420, 840)),
    );
  });
}
