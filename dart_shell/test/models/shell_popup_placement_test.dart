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

  test('centered placement has no hover trigger', () {
    const placement = ShellPopupPlacement(
      anchor: ShellPopupAnchor.center,
      width: 400,
      height: 400,
      margin: 14,
    );

    expect(placement.edgeTrigger(output), Rect.zero);
  });

  test('a placement can disable its own hover trigger', () {
    const placement = ShellPopupPlacement(
      anchor: ShellPopupAnchor.topLeft,
      width: 400,
      height: 400,
      margin: 14,
      hoverTriggerEnabled: false,
    );

    expect(placement.edgeTrigger(output), Rect.zero);
  });

  test('centered triggers accept the requested extent beyond half an edge', () {
    const top = ShellPopupPlacement(
      anchor: ShellPopupAnchor.topCenter,
      width: 400,
      height: 400,
      margin: 14,
    );
    const right = ShellPopupPlacement(
      anchor: ShellPopupAnchor.centerRight,
      width: 400,
      height: 400,
      margin: 14,
    );

    expect(
      top.edgeTrigger(output, thickness: 14, extent: 600),
      const Rect.fromLTWH(1300, 100, 600, 14),
    );
    expect(
      right.edgeTrigger(output, thickness: 14, extent: 500),
      const Rect.fromLTWH(1986, 150, 14, 500),
    );
  });

  test('unbounded corner triggers split the actual edge without overlap', () {
    const topLeft = ShellPopupPlacement(
      anchor: ShellPopupAnchor.topLeft,
      width: 400,
      height: 400,
      margin: 14,
    );
    const bottomLeft = ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomLeft,
      width: 400,
      height: 400,
      margin: 14,
    );

    final top = topLeft.edgeTrigger(output, extent: double.infinity);
    final bottom = bottomLeft.edgeTrigger(output, extent: double.infinity);

    expect(top, const Rect.fromLTWH(1200, 100, 8, 300));
    expect(bottom, const Rect.fromLTWH(1200, 400, 8, 300));
    expect(top.bottom, bottom.top);
    expect(output.contains(top.topLeft), isTrue);
    expect(
      output.contains(bottom.bottomRight - const Offset(0.001, 0.001)),
      isTrue,
    );
  });
}
