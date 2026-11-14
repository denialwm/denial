/// What the phone does with the apps the user leaves.
///
/// An app left for a window opened over it, such as a dialog of its own
/// that Android runs in another task, keeps running while that window is in
/// front over it: the dialog may hand its answer back to it. It is minimized
/// once no window opened over it is in front.
library;

/// The apps to minimize now, and the apps held running behind the front
/// window.
typedef LeftApps = ({List<int> minimize, Set<int> held});

/// [previous] and [front] are the windows in front before and now; [held] is
/// what the last call held; [parentOf] gives a window's parent.
LeftApps leaveApps({
  required int? previous,
  required int? front,
  required Set<int> held,
  required int? Function(int window) parentOf,
}) {
  final minimize = <int>[];
  final keep = <int>{};
  for (final app in {...held, ?previous}) {
    // An app back in front is neither held nor left.
    if (app == front) continue;
    if (_opensOver(front, app, parentOf)) {
      keep.add(app);
    } else {
      minimize.add(app);
    }
  }
  return (minimize: minimize, held: keep);
}

/// Whether [window] is a child of [app], at any depth.
bool _opensOver(int? window, int app, int? Function(int window) parentOf) {
  var id = window;
  // Parents form a tree; the bound only guards a broken one.
  for (var depth = 0; id != null && depth < 16; depth++) {
    final parent = parentOf(id);
    if (parent == app) return true;
    id = parent;
  }
  return false;
}
