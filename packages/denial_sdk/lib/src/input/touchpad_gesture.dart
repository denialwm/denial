import 'dart:math' as math;

/// Relative motion, two-finger scrolling/taps and double-tap dragging.
/// Pointer IDs remain captured until their complete contact sequence ends.
class TouchpadGesture {
  TouchpadGesture({
    required this.motion,
    required this.scroll,
    required this.button,
  });
  final void Function(double dx, double dy) motion;
  final void Function(double dx, double dy, bool stop) scroll;
  final void Function(int button, bool pressed) button;
  final _contacts = <int, _Contact>{};
  Duration _started = Duration.zero;
  Duration? _lastTap;
  int _peak = 0;
  bool _moved = false;
  bool _scrolling = false;
  bool _dragging = false;
  bool _cancelled = false;

  void down(int id, double x, double y, Duration time) {
    if (_contacts.containsKey(id)) return;
    if (_contacts.isEmpty) {
      _started = time;
      _peak = 0;
      _moved = false;
      _cancelled = false;
      if (_lastTap != null &&
          time - _lastTap! <= const Duration(milliseconds: 300)) {
        _dragging = true;
        button(0x110, true);
      }
      _lastTap = null;
    }
    _contacts[id] = _Contact(x, y);
    _peak = math.max(_peak, _contacts.length);
    if (_contacts.length > 1 && _dragging) {
      button(0x110, false);
      _dragging = false;
      _cancelled = true;
    }
  }

  void move(int id, double x, double y) {
    final contact = _contacts[id];
    if (contact == null) return;
    final dx = x - contact.x;
    final dy = y - contact.y;
    contact.x = x;
    contact.y = y;
    contact.travel += math.sqrt(dx * dx + dy * dy);
    if (contact.travel > 8) _moved = true;
    if (_contacts.length == 1 && _peak == 1) {
      motion(dx, dy);
    } else if (_contacts.length == 2 && _peak == 2) {
      _scrolling = true;
      scroll(dx / 2, dy / 2, false);
    }
  }

  void up(int id, Duration time, {bool cancelled = false}) {
    if (_contacts.remove(id) == null) return;
    _cancelled |= cancelled;
    if (_scrolling && _contacts.length < 2) {
      scroll(0, 0, true);
      _scrolling = false;
    }
    if (_contacts.isNotEmpty) return;
    if (_dragging) {
      button(0x110, false);
      _dragging = false;
    } else if (!_cancelled &&
        !_moved &&
        _peak <= 2 &&
        time - _started <= const Duration(milliseconds: 250)) {
      final code = _peak == 2 ? 0x111 : 0x110;
      button(code, true);
      button(code, false);
      if (_peak == 1) _lastTap = time;
    }
  }

  void cancel() {
    if (_dragging) button(0x110, false);
    if (_scrolling) scroll(0, 0, true);
    _contacts.clear();
    _lastTap = null;
    _dragging = false;
    _scrolling = false;
  }
}

class _Contact {
  _Contact(this.x, this.y);
  double x;
  double y;
  double travel = 0;
}
