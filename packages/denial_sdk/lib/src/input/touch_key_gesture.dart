/// Tap/hold arbitration for an on-screen key sharing its surface with swipes.
/// The host supplies a hold timer; this class owns balanced transitions and
/// prevents a pending tap/hold from firing after movement or cancellation.
class TouchKeyGesture {
  TouchKeyGesture({required this.transition});
  final void Function(bool pressed, bool cancelled) transition;
  final _contacts = <int, (double, double)>{};
  bool _pressed = false;
  bool _cancelled = false;

  bool get hasContacts => _contacts.isNotEmpty;

  void down(int id, double x, double y, {required bool immediate}) {
    if (_contacts.containsKey(id)) return;
    if (_contacts.isEmpty) _cancelled = false;
    _contacts[id] = (x, y);
    if (immediate) hold();
  }

  void move(int id, double x, double y) {
    final start = _contacts[id];
    if (start == null) return;
    final dx = x - start.$1;
    final dy = y - start.$2;
    if (dx * dx + dy * dy > 64) {
      _cancelled = true;
      _release(cancelled: true);
    }
  }

  void hold() {
    if (!hasContacts || _cancelled || _pressed) return;
    _pressed = true;
    transition(true, false);
  }

  void up(int id, {bool cancelled = false}) {
    if (_contacts.remove(id) == null) return;
    _cancelled |= cancelled;
    if (_cancelled) _release(cancelled: true);
    if (hasContacts) return;
    if (!_cancelled && !_pressed) {
      _pressed = true;
      transition(true, false);
    }
    _release(cancelled: _cancelled);
  }

  void cancel() {
    _contacts.clear();
    _cancelled = true;
    _release(cancelled: true);
  }

  void _release({required bool cancelled}) {
    if (!_pressed) return;
    _pressed = false;
    transition(false, cancelled);
  }
}
