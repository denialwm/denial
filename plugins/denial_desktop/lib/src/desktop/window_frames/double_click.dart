/// Tells the second press of a double click from a new press.
///
/// The title bar starts a move on a press, so it cannot wait for a release:
/// two presses close in time and place are a double click.
final class DoubleClick {
  DoubleClick({
    this.interval = const Duration(milliseconds: 400),
    this.slop = 6.0,
  });

  /// The longest time between the two presses.
  final Duration interval;

  /// How far apart the two presses may be, in logical pixels per axis.
  final double slop;

  Duration? _lastTime;
  double _lastX = 0.0;
  double _lastY = 0.0;

  /// Records a press at [time] and returns whether it completes a double
  /// click. A completed double click starts over: a third press is a first.
  bool press(Duration time, double x, double y) {
    final lastTime = _lastTime;
    if (lastTime != null &&
        time >= lastTime &&
        time - lastTime <= interval &&
        (x - _lastX).abs() <= slop &&
        (y - _lastY).abs() <= slop) {
      _lastTime = null;
      return true;
    }
    _lastTime = time;
    _lastX = x;
    _lastY = y;
    return false;
  }
}
