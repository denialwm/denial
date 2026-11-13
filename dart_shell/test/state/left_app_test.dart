import 'package:denial_desktop/src/state/left_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Window 2 is a dialog of app 1, 3 a dialog of that dialog; 4 is another app.
  int? parentOf(int window) => switch (window) {
    2 => 1,
    3 => 2,
    _ => null,
  };

  LeftApps leave(int? previous, int? front, [Set<int> held = const {}]) =>
      leaveApps(
        previous: previous,
        front: front,
        held: held,
        parentOf: parentOf,
      );

  test('an app left for another app is minimized', () {
    expect(leave(1, 4), (minimize: [1], held: <int>{}));
  });

  test('an app left for home is minimized', () {
    expect(leave(4, null), (minimize: [4], held: <int>{}));
  });

  test('an app runs on behind its dialog', () {
    expect(leave(1, 2), (minimize: <int>[], held: {1}));
  });

  test('a dialog of a dialog holds both', () {
    expect(leave(2, 3, {1}), (minimize: <int>[], held: {1, 2}));
  });

  test('the dialog closing brings its app back without minimizing it', () {
    expect(leave(2, 1, {1}), (minimize: [2], held: <int>{}));
  });

  test('leaving the dialog for another app minimizes both', () {
    expect(leave(2, 4, {1}), (minimize: [1, 2], held: <int>{}));
  });

  test('a dialog that loses its parent leaves its app minimized', () {
    final left = leaveApps(
      previous: 2,
      front: 2,
      held: {1},
      parentOf: (_) => null,
    );
    expect(left, (minimize: [1], held: <int>{}));
  });

  test('nothing changes while the same window stays in front', () {
    expect(leave(4, 4), (minimize: <int>[], held: <int>{}));
    expect(leave(2, 2, {1}), (minimize: <int>[], held: {1}));
  });
}
