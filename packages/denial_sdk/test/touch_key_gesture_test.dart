import 'package:denial_sdk/input.dart';
import 'package:test/test.dart';

void main() {
  late List<(bool, bool)> transitions;
  late TouchKeyGesture key;
  setUp(() {
    transitions = [];
    key = TouchKeyGesture(
      transition: (pressed, cancelled) => transitions.add((pressed, cancelled)),
    );
  });

  test('ordinary taps send a complete native lifecycle only on release', () {
    key.down(1, 10, 20, immediate: false);
    expect(transitions, isEmpty);
    key.up(1);
    expect(transitions, [(true, false), (false, false)]);
  });

  test('swiping off a pending key never types or starts a delayed hold', () {
    key.down(1, 10, 20, immediate: false);
    key.move(1, 10, 30);
    key.hold();
    key.up(1);
    expect(transitions, isEmpty);
  });

  test('modifiers and active chords press immediately and cancel cleanly', () {
    key.down(1, 0, 0, immediate: true);
    expect(transitions, [(true, false)]);
    key.move(1, 20, 0);
    key.up(1);
    expect(transitions, [(true, false), (false, true)]);
  });

  test('a stationary hold starts a native press and ends on finger lift', () {
    key.down(1, 10, 20, immediate: false);
    key.hold();
    key.hold();
    key.up(1);
    expect(transitions, [(true, false), (false, false)]);
  });

  test('cancellation or disposal cannot activate a queued timer', () {
    key.down(1, 10, 20, immediate: false);
    key.cancel();
    key.hold();
    key.up(1);
    expect(transitions, isEmpty);
    key.down(2, 0, 0, immediate: true);
    key.cancel();
    key.cancel();
    expect(transitions, [(true, false), (false, true)]);
  });

  test('multiple contacts on the same key balance one shared press', () {
    key.down(1, 0, 0, immediate: true);
    key.down(2, 0, 0, immediate: true);
    key.up(1);
    expect(transitions, [(true, false)]);
    key.up(2);
    expect(transitions, [(true, false), (false, false)]);
  });
}
