import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const output = Rect.fromLTWH(0, 0, 1920, 1080);

  test('a stationary window is clipped to its output', () {
    expect(
      desktopOutputClip(
        activelyDragging: false,
        outputRect: output,
      ),
      output,
    );
  });

  test('overview and pinned presentation cannot bypass the output clip', () {
    // Presentation state is deliberately absent from the clip API. Overview
    // transforms and pinned stacking must use the same owning-output cut.
    expect(
      desktopOutputClip(
        activelyDragging: false,
        outputRect: output,
      ),
      output,
    );
  });

  test('missing output geometry does not create a clip', () {
    expect(
      desktopOutputClip(
        activelyDragging: false,
        outputRect: null,
      ),
      isNull,
    );
  });

  test('an actively dragged window can cross output boundaries', () {
    expect(
      desktopOutputClip(
        activelyDragging: true,
        outputRect: output,
      ),
      isNull,
    );
  });
}
