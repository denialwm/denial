import 'dart:ui' as ui;

import 'package:denial_dart_shell/src/desktop/desktop_panel_transition.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/shell_backdrop_blur.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('centered panel fades one completed backdrop material', (
    tester,
  ) async {
    const childKey = ValueKey<String>('panel-content');

    await tester.pumpWidget(_harness(visible: true, childKey: childKey));
    await tester.pumpWidget(_harness(visible: false, childKey: childKey));
    await tester.pump(const Duration(milliseconds: 40));

    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.byKey(childKey),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));

    final backdrop = tester.widget<ShellBackdropBlur>(
      find.ancestor(
        of: find.byKey(childKey),
        matching: find.byType(ShellBackdropBlur),
      ),
    );
    expect(backdrop.strength, 1);
    expect(backdrop.blendMode, ui.BlendMode.srcOver);
  });
}

Widget _harness({required bool visible, required Key childKey}) {
  return ProviderScope(
    child: MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ShellTheme(
          data: const ShellThemeData(),
          child: SizedBox(
            width: 400,
            height: 300,
            child: DesktopPanelTransition(
              inputDebugLabel: 'Test panel',
              visible: visible,
              entryDirection: Offset.zero,
              maintainState: true,
              child: SizedBox(key: childKey),
            ),
          ),
        ),
      ),
    ),
  );
}
