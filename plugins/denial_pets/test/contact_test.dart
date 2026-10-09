import 'package:denial_pets/src/contact.dart';
import 'package:test/test.dart';

void main() {
  const anchor = (x: 200.0, y: 600.0);
  const reach = 75.0;

  test('an edge fades across it, both ways from the anchor', () {
    for (final hold in [1, 2]) {
      final fade =
          contactFade(hold: hold, anchor: anchor, reach: reach) as AcrossEdge;
      expect(fade.from, (x: 200.0, y: 600.0 - reach));
      expect(fade.to, (x: 200.0, y: 600.0 + reach));
    }
    for (final hold in [4, 8]) {
      final fade =
          contactFade(hold: hold, anchor: anchor, reach: reach) as AcrossEdge;
      expect(fade.from, (x: 200.0 - reach, y: 600.0));
      expect(fade.to, (x: 200.0 + reach, y: 600.0));
    }
  });

  test('a corner fades around its point', () {
    for (final hold in [16, 32, 64, 128]) {
      final fade =
          contactFade(hold: hold, anchor: anchor, reach: reach) as AroundCorner;
      expect(fade.center, anchor);
      expect(fade.radius, reach);
    }
  });

  test('anything else casts nothing', () {
    expect(contactFade(hold: 0, anchor: anchor, reach: reach), isNull);
    expect(contactFade(hold: 1 | 2, anchor: anchor, reach: reach), isNull);
  });
}
