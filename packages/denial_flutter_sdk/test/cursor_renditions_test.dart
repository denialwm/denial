import 'dart:io';

import 'package:denial_flutter_sdk/src/theme/cursor_themes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final normal = ShellCursorThemes.bibataModernIce.roleFor(
    ShellCursorKind.normal,
  );

  test('a cursor at its native size draws the native artwork', () {
    expect(normal.renditionFor(32), isNull);
    expect(normal.renditionFor(32.0000001), isNull);
    expect(normal.renditionFor(24), isNull);
  });

  test('a larger cursor draws the smallest rendition that reaches it', () {
    expect(normal.renditionFor(40)?.extent, 48);
    expect(normal.renditionFor(48)?.extent, 48);
    expect(normal.renditionFor(64)?.extent, 64);
    // 32 px on a 215.83 % display.
    expect(normal.renditionFor(32 * 2.1583)?.extent, 96);
  });

  test('past the largest rendition the largest is scaled up', () {
    expect(normal.renditionFor(192)?.extent, 96);
  });

  test('a rendition has its own hotspot and folder', () {
    final rendition = normal.renditionFor(64)!;
    expect(rendition.hotspot, const Offset(13, 4));
    expect(normal.relativeFramePath(0, rendition), 'normal/64/00.png');
  });

  test('every bundled frame and rendition exists', () {
    const prefix = 'packages/denial_flutter_sdk/';
    final paths = ShellCursorThemes.bibataModernIce.assetPaths.toList();
    expect(paths, hasLength(ShellCursorKind.values.length * 4));
    for (final path in paths) {
      expect(path, startsWith(prefix));
      expect(
        File(path.substring(prefix.length)).existsSync(),
        isTrue,
        reason: path,
      );
    }
  });
}
