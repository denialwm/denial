import 'package:denial_dart_shell/src/desktop/desktop_pixel_alignment.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aligns a decorated client origin at fractional DPR', () {
    final aligned = desktopPixelAlignedWindowFrame(
      frame: const Rect.fromLTWH(100, 120, 802, 602),
      contentInset: 1,
      devicePixelRatio: 1.5,
      enabled: true,
    );

    expect(aligned.size, const Size(802, 602));
    expect((aligned.left + 1) * 1.5, closeTo(152, 0.000001));
    expect((aligned.top + 1) * 1.5, closeTo(182, 0.000001));
  });

  test('preserves size while aligning a moving frame', () {
    const frame = Rect.fromLTWH(100.2, 120.4, 803, 603);

    final aligned = desktopPixelAlignedWindowFrame(
      frame: frame,
      contentInset: 1,
      devicePixelRatio: 1.5,
      enabled: true,
    );

    expect(aligned.width, closeTo(frame.width, 0.000001));
    expect(aligned.height, closeTo(frame.height, 0.000001));
    expect((aligned.left + 1) * 1.5, closeTo(152, 0.000001));
    expect((aligned.top + 1) * 1.5, closeTo(182, 0.000001));
  });

  test('aligns every changing content edge while resizing', () {
    final aligned = desktopPixelAlignedWindowFrame(
      frame: const Rect.fromLTWH(100.2, 120.4, 803, 603),
      contentInset: 1,
      devicePixelRatio: 1.5,
      enabled: true,
      alignSize: true,
    );

    expect((aligned.left + 1) * 1.5, closeTo(152, 0.000001));
    expect((aligned.top + 1) * 1.5, closeTo(182, 0.000001));
    expect((aligned.right - 1) * 1.5, closeTo(1353, 0.000001));
    expect((aligned.bottom - 1) * 1.5, closeTo(1084, 0.000001));
    expect(aligned.width, closeTo(802 + 2 / 3, 0.000001));
    expect(aligned.height, closeTo(603 + 1 / 3, 0.000001));
  });

  test('aligns a client-decorated frame without an inset', () {
    final aligned = desktopPixelAlignedWindowFrame(
      frame: const Rect.fromLTWH(101, 41, 800, 600),
      contentInset: 0,
      devicePixelRatio: 1.5,
      enabled: true,
    );

    expect(aligned.size, const Size(800, 600));
    expect(aligned.left * 1.5, closeTo(152, 0.000001));
    expect(aligned.top * 1.5, closeTo(62, 0.000001));
  });

  test('leaves deliberately transformed frames untouched', () {
    const frame = Rect.fromLTWH(101, 41, 800, 600);

    expect(
      desktopPixelAlignedWindowFrame(
        frame: frame,
        contentInset: 0,
        devicePixelRatio: 1.5,
        enabled: false,
      ),
      frame,
    );
  });
}
