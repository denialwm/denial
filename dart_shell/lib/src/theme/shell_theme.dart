import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'tokens.dart';

@immutable
class ShellThemeData {
  const ShellThemeData({
    this.accent = ShellColors.accent,
    this.windowRadius = ShellRadii.window,
    this.panelRadius = ShellRadii.panel,
    this.panelOpacity = 0.93,
    this.focusedWindowOpacity = 1,
    this.unfocusedWindowOpacity = 1,
  });

  final Color accent;
  final double windowRadius;
  final double panelRadius;
  final double panelOpacity;
  final double focusedWindowOpacity;
  final double unfocusedWindowOpacity;

  Color panelColor(Color color) => color.withValues(alpha: panelOpacity);

  @override
  bool operator ==(Object other) {
    return other is ShellThemeData &&
        other.accent == accent &&
        other.windowRadius == windowRadius &&
        other.panelRadius == panelRadius &&
        other.panelOpacity == panelOpacity &&
        other.focusedWindowOpacity == focusedWindowOpacity &&
        other.unfocusedWindowOpacity == unfocusedWindowOpacity;
  }

  @override
  int get hashCode => Object.hash(
    accent,
    windowRadius,
    panelRadius,
    panelOpacity,
    focusedWindowOpacity,
    unfocusedWindowOpacity,
  );
}

class ShellTheme extends InheritedWidget {
  const ShellTheme({required this.data, required super.child, super.key});

  final ShellThemeData data;

  static ShellThemeData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ShellTheme>()?.data ??
        const ShellThemeData();
  }

  @override
  bool updateShouldNotify(covariant ShellTheme oldWidget) {
    return oldWidget.data != data;
  }
}
