import 'package:denial_flutter_sdk/src/state/display_brightness_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a display has no level until the system reports one', () {
    final model = DisplayBrightnessModel([1, 2]);

    expect(model.state.levels, isEmpty);
    expect(model.state.loading, {1, 2});
  });

  test('a level nothing reported cannot be changed', () {
    final model = DisplayBrightnessModel([1]);

    final state = model.setLevel(1, 0.5);

    expect(state.levels, isEmpty);
  });

  test('a read without an answer leaves the display without a level', () {
    final model = DisplayBrightnessModel([1]);
    final token = model.beginRead(1)!;

    final state = model.completeRead(1, token, null);

    expect(state.levels, isEmpty);
    expect(state.loading, isEmpty);
  });

  test('a reported level can then be changed', () {
    final model = DisplayBrightnessModel([1]);
    final token = model.beginRead(1)!;
    model.completeRead(1, token, 0.4);

    expect(model.state.levels, {1: 0.4});
    expect(model.setLevel(1, 0.8).levels, {1: 0.8});
  });

  test('a native event gives an unread display its level', () {
    final model = DisplayBrightnessModel([1]);

    final state = model.nativeLevel(1, 0.6, completesRead: false);

    expect(state.levels, {1: 0.6});
  });

  test('an unknown display is ignored', () {
    final model = DisplayBrightnessModel([1]);

    expect(model.beginRead(9), isNull);
    expect(model.nativeLevel(9, 0.6, completesRead: false).levels, isEmpty);
  });
}
