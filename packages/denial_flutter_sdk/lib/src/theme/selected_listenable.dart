import 'package:flutter/foundation.dart';

/// One aspect of a frequently changing [source], as a [ValueListenable] that
/// notifies only when that aspect changes.
///
/// Motion values change on every frame. A widget that depends only on a
/// threshold of one (a progress reaching its end, a drag changing direction)
/// listens to a selection of it and rebuilds when the threshold is crossed,
/// not once per frame. The source is observed only while this has listeners.
class SelectedListenable<T> extends ChangeNotifier
    implements ValueListenable<T> {
  SelectedListenable(this.source, this.select);

  final Listenable source;
  final ValueGetter<T> select;

  late T _value;
  bool _observing = false;

  @override
  T get value => _observing ? _value : select();

  @override
  void addListener(VoidCallback listener) {
    if (!_observing) {
      _value = select();
      source.addListener(_update);
      _observing = true;
    }
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_observing && !hasListeners) {
      source.removeListener(_update);
      _observing = false;
    }
  }

  @override
  void dispose() {
    if (_observing) {
      source.removeListener(_update);
      _observing = false;
    }
    super.dispose();
  }

  void _update() {
    final next = select();
    if (next == _value) {
      return;
    }
    _value = next;
    notifyListeners();
  }
}
