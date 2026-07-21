import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/tokens.dart';

@immutable
class ShellAppearance {
  const ShellAppearance({
    this.focusedWindowBorderColor = ShellColors.focusedWindowBorder,
  });

  final Color focusedWindowBorderColor;

  ShellAppearance copyWith({Color? focusedWindowBorderColor}) {
    return ShellAppearance(
      focusedWindowBorderColor:
          focusedWindowBorderColor ?? this.focusedWindowBorderColor,
    );
  }
}

final shellAppearanceProvider =
    StateNotifierProvider<ShellAppearanceController, ShellAppearance>((ref) {
  return ShellAppearanceController();
});

class ShellAppearanceController extends StateNotifier<ShellAppearance> {
  ShellAppearanceController([ShellAppearance initial = const ShellAppearance()])
      : super(initial);

  void setFocusedWindowBorderColor(Color color) {
    final opaque = color.withAlpha(0xff);
    if (opaque == state.focusedWindowBorderColor) {
      return;
    }
    state = state.copyWith(focusedWindowBorderColor: opaque);
  }

  void resetFocusedWindowBorderColor() {
    setFocusedWindowBorderColor(ShellColors.focusedWindowBorder);
  }
}
