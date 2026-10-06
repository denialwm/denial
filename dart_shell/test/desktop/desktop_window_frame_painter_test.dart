import 'dart:ui' as ui;

import 'package:denial_dart_shell/src/desktop/desktop_window_frame_painter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rounded frame keeps a one logical pixel border', () {
    final geometry = desktopRoundedFrameGeometry(
      size: const Size(800, 600),
      radius: 8,
      frameThickness: 1,
      borderThickness: 1,
      devicePixelRatio: 1.25,
    );

    expect(geometry.outerRadius, 8);
    expect(geometry.innerRadius, 7);
    expect(geometry.borderThickness, 1);
    expect(geometry.edgeHalfWidth * 2 * 1.25, closeTo(1, 0.000001));
    expect(geometry.borderThickness * 1.25, closeTo(1.25, 0.000001));
    expect(geometry.shaderRadius, 8.4);
  });

  test('only the antialiasing fringe is fixed to one physical pixel', () {
    for (final ratio in <double>[1, 1.25, 1.5, 2]) {
      final geometry = desktopRoundedFrameGeometry(
        size: const Size(800, 600),
        radius: 8,
        frameThickness: 1,
        borderThickness: 1,
        devicePixelRatio: ratio,
      );

      expect(
        geometry.edgeHalfWidth * 2 * ratio,
        closeTo(1, 0.000001),
        reason: 'coverage width at ${ratio}x',
      );
      expect(
        geometry.borderThickness,
        1,
        reason: 'logical border width at ${ratio}x',
      );
      expect(
        geometry.borderThickness * ratio,
        closeTo(ratio, 0.000001),
        reason: 'physical border coverage at ${ratio}x',
      );
    }
  });

  test('rounded frame geometry clamps unsafe inputs', () {
    final geometry = desktopRoundedFrameGeometry(
      size: const Size(10, 4),
      radius: 20,
      frameThickness: 8,
      borderThickness: 3,
      devicePixelRatio: double.nan,
    );

    expect(geometry.outerRadius, 2);
    expect(geometry.innerRadius, 0);
    expect(geometry.frameThickness, 2);
    expect(geometry.borderThickness, 2);
    expect(geometry.edgeHalfWidth, 0.5);
    expect(geometry.shaderRadius, 2.5);
  });

  test('frame painter repaints only when its visual inputs change', () {
    const frameColor = Color(0xff1a1d23);
    const borderColor = Color(0x2effffff);
    const painter = DesktopWindowFramePainter(
      windowId: 7,
      devicePixelRatio: 1.25,
      radius: 8,
      frameColor: frameColor,
      borderColor: borderColor,
    );

    expect(
      painter.shouldRepaint(
        const DesktopWindowFramePainter(
          windowId: 7,
          devicePixelRatio: 1.25,
          radius: 8,
          frameColor: frameColor,
          borderColor: borderColor,
        ),
      ),
      isFalse,
    );
    expect(
      painter.shouldRepaint(
        const DesktopWindowFramePainter(
          windowId: 7,
          devicePixelRatio: 1.5,
          radius: 8,
          frameColor: frameColor,
          borderColor: borderColor,
        ),
      ),
      isTrue,
    );
  });

  test('frame painter records valid commands for supported output scales', () {
    for (final ratio in <double>[1, 1.25, 1.5, 2]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      DesktopWindowFramePainter(
        windowId: 7,
        devicePixelRatio: ratio,
        radius: 8,
        frameColor: const Color(0xff1a1d23),
        borderColor: const Color(0x2effffff),
      ).paint(canvas, const Size(800, 600));

      final picture = recorder.endRecording();
      expect(picture.approximateBytesUsed, greaterThan(0));
      picture.dispose();
    }
  });

  test('frame painter records valid commands for a constrained frame', () {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const DesktopWindowFramePainter(
      windowId: 7,
      devicePixelRatio: 1.25,
      radius: 20,
      frameColor: Color(0xff1a1d23),
    ).paint(canvas, const Size(10, 4));

    final picture = recorder.endRecording();
    expect(picture.approximateBytesUsed, greaterThan(0));
    picture.dispose();
  });
}
