import 'package:denial_sdk/input.dart';
import 'package:test/test.dart';

void main() {
  late List<Object> events;
  late TouchpadGesture pad;
  setUp(() {
    events = [];
    pad = TouchpadGesture(
      motion: (x, y) => events.add(('motion', x, y)),
      scroll: (x, y, stop) => events.add(('scroll', x, y, stop)),
      button: (code, pressed) => events.add(('button', code, pressed)),
    );
  });

  test(
    'relative motion does not warp to the finger or click after dragging',
    () {
      pad.down(1, 500, 200, Duration.zero);
      pad.move(1, 520, 190);
      pad.up(1, const Duration(milliseconds: 100));
      expect(events, [('motion', 20.0, -10.0)]);
    },
  );

  test('two-finger tap produces a right click and never a left click', () {
    pad.down(1, 10, 10, Duration.zero);
    pad.down(2, 20, 10, const Duration(milliseconds: 10));
    pad.up(2, const Duration(milliseconds: 100));
    pad.up(1, const Duration(milliseconds: 120));
    expect(events, [('button', 0x111, true), ('button', 0x111, false)]);
  });

  test(
    'two-finger scroll ends when one finger lifts without moving the cursor',
    () {
      pad.down(1, 10, 10, Duration.zero);
      pad.down(2, 20, 10, Duration.zero);
      pad.move(1, 10, 30);
      pad.move(2, 20, 30);
      pad.up(2, const Duration(milliseconds: 100));
      pad.move(1, 10, 50);
      pad.up(1, const Duration(milliseconds: 150));
      expect(events, [
        ('scroll', 0.0, 10.0, false),
        ('scroll', 0.0, 10.0, false),
        ('scroll', 0.0, 0.0, true),
      ]);
    },
  );

  test(
    'double tap holds a drag until release and cancellation balances it',
    () {
      pad.down(1, 0, 0, Duration.zero);
      pad.up(1, const Duration(milliseconds: 80));
      pad.down(2, 0, 0, const Duration(milliseconds: 150));
      pad.move(2, 30, 0);
      pad.cancel();
      pad.up(2, const Duration(milliseconds: 200));
      expect(events, [
        ('button', 0x110, true),
        ('button', 0x110, false),
        ('button', 0x110, true),
        ('motion', 30.0, 0.0),
        ('button', 0x110, false),
      ]);
    },
  );

  test('cancelled and three-finger sequences never become clicks', () {
    pad.down(1, 0, 0, Duration.zero);
    pad.up(1, const Duration(milliseconds: 30), cancelled: true);
    for (final id in [1, 2, 3]) {
      pad.down(id, 0, 0, const Duration(milliseconds: 100));
    }
    for (final id in [1, 2, 3]) {
      pad.up(id, const Duration(milliseconds: 130));
    }
    expect(events, isEmpty);
  });
}
