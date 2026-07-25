import 'package:denial_dart_shell/src/desktop/desktop_texture_resize.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enables smooth sampling while the client geometry trails the frame',
      () {
    expect(
      desktopTextureNeedsResizeSmoothing(
        targetSize: const Size(1600, 900),
        sourceSize: const Size(1000, 700),
      ),
      isTrue,
    );
  });

  test('ignores fractional geometry noise once sizes have converged', () {
    expect(
      desktopTextureNeedsResizeSmoothing(
        targetSize: const Size(1600, 900),
        sourceSize: const Size(1599.6, 900.3),
      ),
      isFalse,
    );
  });
}
