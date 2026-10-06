import 'package:denial_dart_shell/src/desktop/desktop_pixel_alignment.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aligns content to its output-local physical pixel grid', () {
    const outputOrigin = Offset(1921, 37);
    final aligned = desktopPixelAlignedWindowFrame(
      frame: const Rect.fromLTWH(2021.2, 157.4, 803, 603),
      contentInset: 1,
      devicePixelRatio: 1.25,
      pixelGridOrigin: outputOrigin,
      enabled: true,
      alignSize: true,
    );

    expect((aligned.left + 1 - outputOrigin.dx) * 1.25, closeTo(127, 0.000001));
    expect((aligned.top + 1 - outputOrigin.dy) * 1.25, closeTo(152, 0.000001));
    expect(
      (aligned.right - 1 - outputOrigin.dx) * 1.25,
      closeTo(1128, 0.000001),
    );
    expect(
      (aligned.bottom - 1 - outputOrigin.dy) * 1.25,
      closeTo(903, 0.000001),
    );
  });
}
