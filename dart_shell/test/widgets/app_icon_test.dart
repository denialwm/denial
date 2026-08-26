import 'dart:io';

import 'package:denial_dart_shell/src/widgets/app_icon.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop SVG loaders share a path-based cache key', () {
    final first = DesktopAppSvgLoader('/usr/share/icons/example.svg');
    final second = DesktopAppSvgLoader('/usr/share/icons/example.svg');
    final different = DesktopAppSvgLoader('/usr/share/icons/different.svg');

    expect(first, second);
    expect(first.cacheKey(null), second.cacheKey(null));
    expect(first, isNot(different));
    expect(first.cacheKey(null), isNot(different.cacheKey(null)));

    expect(first, isNot(SvgFileLoader(File('/usr/share/icons/example.svg'))));
  });
}
