import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/edge_panel_layer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('open keyboard right edge scrolls the viewport both ways', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 840);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellControllerProvider.overrideWith(_OpenEdgePanelController.new),
        ],
        child: const DenialLocalizationScope(
          locale: Locale('en'),
          child: ShellTheme(
            data: ShellThemeData(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: MediaQueryData(size: Size(420, 840)),
                child: SizedBox(
                  width: 420,
                  height: 840,
                  child: MobileSystemKeyboardLayer(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MobileSystemKeyboardLayer)),
    );
    final gesture = await tester.startGesture(const Offset(419, 160));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();

    final scrolledDown = container
        .read(shellControllerProvider)
        .edgePanelViewportScroll;
    expect(scrolledDown, greaterThan(0));

    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(
      container.read(shellControllerProvider).edgePanelViewportScroll,
      lessThan(scrolledDown),
    );

    await gesture.up();
  });
}

class _OpenEdgePanelController extends ShellController {
  @override
  ShellState build() =>
      ShellState.initial(locked: false).copyWith(edgePanelVisible: true);
}
