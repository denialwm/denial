import 'dart:async';

import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/system_level_hud.dart';
import 'package:denial_dart_shell/src/widgets/system_level_hud.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('latest level update uses the correct output and presentation',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 800);
    addTearDown(tester.view.reset);

    final brightnessUpdates =
        StreamController<DenialBrightnessState>.broadcast(sync: true);
    final audioUpdates =
        StreamController<DenialAudioState>.broadcast(sync: true);
    final hudController = SystemLevelHudController(
      brightnessStates: brightnessUpdates.stream,
      audioStates: audioUpdates.stream,
      visibleDuration: const Duration(minutes: 1),
    );
    final layoutBridge = _LayoutBridge(_dualOutputLayout);
    final container = ProviderContainer(
      overrides: <Override>[
        systemLevelHudProvider.overrideWith((ref) => hudController),
        displayLayoutProvider.overrideWith(
          (ref) => DisplayLayoutController(layoutBridge),
        ),
      ],
    );
    var disposed = false;
    Future<void> disposeHarness() async {
      if (disposed) {
        return;
      }
      disposed = true;
      container.dispose();
      await brightnessUpdates.close();
      await audioUpdates.close();
      layoutBridge.dispose();
    }

    addTearDown(disposeHarness);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MediaQuery(
          data: MediaQueryData(
            size: Size(2000, 800),
            disableAnimations: true,
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[SystemLevelHudLayer()],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    audioUpdates.add(const DenialAudioState(
      level: 0.64,
      requestSerial: 5,
    ));
    await tester.pump();

    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('64%'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    final volumeSemantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.text('Volume'),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(volumeSemantics.properties.label, 'Output volume');
    expect(volumeSemantics.properties.value, '64 percent');
    expect(volumeSemantics.properties.liveRegion, isTrue);
    expect(
      tester.getRect(find.byType(IgnorePointer)),
      const Rect.fromLTWH(1410, 698, 380, 74),
    );

    brightnessUpdates.add(const DenialBrightnessState(
      monitorId: 11,
      level: 0.35,
    ));
    await tester.pump();

    expect(find.text('Volume'), findsNothing);
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.text('secondary'), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);
    expect(find.byIcon(Icons.brightness_6_rounded), findsOneWidget);
    expect(
      tester.getRect(find.byType(IgnorePointer)),
      const Rect.fromLTWH(410, 698, 380, 74),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await disposeHarness();
  });
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
