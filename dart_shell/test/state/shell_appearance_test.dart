import 'package:denial_dart_shell/src/state/shell_appearance.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focused border changes immediately and remains opaque', () {
    final container = ProviderContainer.test();
    final controller = container.read(shellAppearanceProvider.notifier);

    controller.setFocusedWindowBorderColor(const Color(0x3378dce8));

    expect(
      container.read(shellAppearanceProvider).focusedWindowBorderColor,
      const Color(0xff78dce8),
    );
  });

  test('focused border can return to the shell default', () {
    final container = ProviderContainer.test();
    final controller = container.read(shellAppearanceProvider.notifier);
    controller.setFocusedWindowBorderColor(const Color(0xff00ff00));

    controller.resetFocusedWindowBorderColor();

    expect(
      container.read(shellAppearanceProvider).focusedWindowBorderColor,
      ShellColors.focusedWindowBorder,
    );
  });
}
