import 'package:flutter/widgets.dart';

/// Tells an in-bundle application to paint a frozen texture during its desktop
/// window's entrance or terminal close animation.
///
/// Native clients already reach shell transitions as compositor textures.
/// Local Flutter applications otherwise carry their complete live layer trees
/// through the same effects, which is considerably more expensive.
class DesktopWindowSnapshotScope extends InheritedWidget {
  const DesktopWindowSnapshotScope({
    required this.snapshotting,
    required super.child,
    super.key,
  });

  final bool snapshotting;

  static bool snapshottingOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<DesktopWindowSnapshotScope>()
            ?.snapshotting ??
        false;
  }

  @override
  bool updateShouldNotify(DesktopWindowSnapshotScope oldWidget) {
    return snapshotting != oldWidget.snapshotting;
  }
}
