import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/screenshot_selection.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/screenshot_selection_layer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('completed selection collapses before native teardown', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 300);
    addTearDown(tester.view.reset);

    final bridge = _ScreenshotBridge();
    addTearDown(bridge.dispose);
    final container = ProviderContainer(
      overrides: [denialBridgeProvider.overrideWithValue(bridge)],
    );
    addTearDown(container.dispose);
    final controller = container.read(screenshotSelectionProvider.notifier);
    expect(controller.prepare(41), isTrue);
    expect(controller.textureReady(41, 9001), isTrue);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const DenialLocalizationScope(
          locale: Locale('en'),
          child: MediaQuery(
            data: MediaQueryData(size: Size(400, 300)),
            child: ShellTheme(
              data: ShellThemeData(),
              child: Stack(children: [ScreenshotSelectionLayer()]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final drag = await tester.startGesture(
      const Offset(40, 50),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await drag.moveTo(const Offset(200, 150));
    await tester.pump();
    expect(find.text('160 × 100'), findsOneWidget);

    await drag.up();
    await tester.pump();

    expect(bridge.finishCalls, 0);
    expect(find.text('160 × 100'), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(
      container.read(screenshotSelectionProvider)!.phase,
      ScreenshotSelectionPhase.selecting,
    );

    await tester.pump(const Duration(milliseconds: 110));
    expect(bridge.finishCalls, 0);
    expect(find.byType(Texture), findsOneWidget);

    await tester.pump(Motion.screenshotTake);
    expect(bridge.finishCalls, 1);
    expect(bridge.requestId, 41);
    expect(bridge.region, const Rect.fromLTWH(40, 50, 160, 100));
    expect(
      container.read(screenshotSelectionProvider)!.phase,
      ScreenshotSelectionPhase.finishing,
    );
    expect(find.byType(Texture), findsNothing);
  });
}

class _ScreenshotBridge extends DenialBridge {
  int finishCalls = 0;
  int? requestId;
  Rect? region;

  @override
  bool finishScreenshotRegion(int requestId, Rect region) {
    finishCalls += 1;
    this.requestId = requestId;
    this.region = region;
    return true;
  }
}
