import 'package:denial_dart_shell/src/settings/color_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opaque color formatting uses exact RGB bytes', () {
    expect(formatOpaqueColorHex(const Color(0xff0c80ff)), '#0C80FF');
    expect(opaqueColorRgb(const Color(0xff0c80ff)), (
      red: 12,
      green: 128,
      blue: 255,
    ));
  });

  test('hex parsing accepts shorthand and familiar prefixes', () {
    expect(parseOpaqueColorHex('#1a2b3c'), const Color(0xff1a2b3c));
    expect(parseOpaqueColorHex('3af'), const Color(0xff33aaff));
    expect(parseOpaqueColorHex('0x00FF7F'), const Color(0xff00ff7f));
  });

  test('hex parsing rejects invalid and alpha-bearing values', () {
    expect(parseOpaqueColorHex('12'), isNull);
    expect(parseOpaqueColorHex('#12345g'), isNull);
    expect(parseOpaqueColorHex('#80123456'), isNull);
  });
}
