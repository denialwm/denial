import 'dart:collection';

import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mobile_motion_harness.dart';

void main() {
  test('1200 drag updates do not scan a 1000-window snapshot', () {
    final windows = _CountingWindows([
      for (var id = 0; id < 1000; id++) motionWindow(id),
    ]);
    var state = ShellState.initial().copyWith(
      windows: windows,
      foregroundObjectId: 500,
    );
    final apps = state.openAppWindows;
    windows.reads = 0;
    for (var tick = 1; tick <= 1200; tick++) {
      state = state.copyWith(gestureDrag: Offset(tick.toDouble(), 0));
      expect(state.appSwitchTargetWindow?.objectId, 499);
      expect(state.adjacentOpenAppWindow(1)?.objectId, 501);
      expect(state.openAppWindows, same(apps));
    }
    expect(windows.reads, 0);
  });

  test(
    'adjacency follows app order after filtering, removal and reordering',
    () {
      final apps = [motionWindow(1), motionWindow(2), motionWindow(3)];
      var state = ShellState.initial().copyWith(
        windows: [
          motionWindow(90, appId: 'denia-home'),
          apps[0],
          motionWindow(91, appId: 'denia-systemui-helper'),
          apps[1],
          apps[2],
        ],
        foregroundObjectId: 2,
      );
      expect(state.adjacentOpenAppWindow(-1), same(apps[0]));
      expect(state.adjacentOpenAppWindow(1), same(apps[2]));
      expect(state.adjacentOpenAppWindow(0), isNull);
      state = state.copyWith(windows: [apps[2], apps[1], apps[0]]);
      expect(state.adjacentOpenAppWindow(-1), same(apps[2]));
      expect(state.adjacentOpenAppWindow(1), same(apps[0]));
      state = state.copyWith(windows: [apps[2], apps[0]]);
      expect(state.adjacentOpenAppWindow(-1), same(apps[2]));
      expect(state.adjacentOpenAppWindow(1), isNull);
      state = state.copyWith(foregroundObjectId: 3);
      expect(state.adjacentOpenAppWindow(-1), isNull);
      expect(state.adjacentOpenAppWindow(1), same(apps[0]));
      state = state.copyWith(windows: [apps[0]]);
      expect(state.adjacentOpenAppWindow(-1), isNull);
      expect(state.adjacentOpenAppWindow(1), isNull);
    },
  );
}

class _CountingWindows extends ListBase<DenialWindow> {
  _CountingWindows(this._values);
  final List<DenialWindow> _values;
  int reads = 0;
  @override
  int get length => _values.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  DenialWindow operator [](int index) {
    reads++;
    return _values[index];
  }

  @override
  void operator []=(int index, DenialWindow value) =>
      throw UnsupportedError('read only');
}
