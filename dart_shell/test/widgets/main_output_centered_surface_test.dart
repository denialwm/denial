import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/widgets/main_output_centered_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'centers its child inside the main output, not the output atlas',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(2000, 800);
      addTearDown(tester.view.reset);
      final bridge = _LayoutBridge(_dualOutputLayout);
      addTearDown(bridge.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            displayLayoutProvider.overrideWith(
              (ref) => DisplayLayoutController(bridge),
            ),
          ],
          child: const MediaQuery(
            data: MediaQueryData(size: Size(2000, 800)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MainOutputCenteredSurface(builder: _testPanel),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getRect(find.byKey(const ValueKey<String>('test-panel'))),
        const Rect.fromLTWH(1500, 350, 200, 100),
      );
    },
  );
}

Widget _testPanel(BuildContext context, BoxConstraints constraints) {
  return const SizedBox(
    key: ValueKey<String>('test-panel'),
    width: 200,
    height: 100,
  );
}

class _LayoutBridge extends DenialBridge {
  _LayoutBridge(this.layout);

  final DisplayLayout layout;

  @override
  Future<DisplayLayout?> getDisplayLayout() async => layout;
}

const _dualOutputLayout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(2000, 800),
  pixelSize: Size(2000, 800),
  engineScale: 1,
  tickerMonitorId: 22,
  systemBarMonitorId: 22,
  systemBarSide: SystemBarSide.left,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 11,
      name: 'secondary',
      logicalRect: Rect.fromLTWH(0, 0, 1200, 800),
      pixelSize: Size(1200, 800),
      scale: 1,
      refreshRate: 60,
    ),
    DisplayOutput(
      monitorId: 22,
      name: 'main',
      logicalRect: Rect.fromLTWH(1200, 0, 800, 800),
      pixelSize: Size(800, 800),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);
