import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const output = Rect.fromLTWH(1200, 100, 800, 600);

  test('all anchors resolve relative to the selected output', () {
    const placement = ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomRight,
      width: 320,
      height: 240,
      margin: 16,
    );

    expect(placement.resolve(output), const Rect.fromLTWH(1664, 444, 320, 240));
  });

  test('hostile persisted sizes remain visible and reachable', () {
    const placement = ShellPopupPlacement(
      anchor: ShellPopupAnchor.center,
      width: double.infinity,
      height: -20,
      margin: 500,
    );

    expect(placement.resolve(output), Rect.zero);
  });

  test('hover trigger follows the nearest configured edge', () {
    const right = ShellPopupPlacement(
      anchor: ShellPopupAnchor.centerRight,
      width: 400,
      height: 400,
      margin: 14,
    );
    const bottom = ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomCenter,
      width: 400,
      height: 400,
      margin: 14,
    );

    expect(right.edgeTrigger(output), const Rect.fromLTWH(1992, 352, 8, 96));
    expect(bottom.edgeTrigger(output), const Rect.fromLTWH(1552, 692, 96, 8));
  });
}
