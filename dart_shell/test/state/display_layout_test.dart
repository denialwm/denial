import 'dart:async';

import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shell work-area metrics publish even when placement follows native',
    () async {
      final bridge = _FakeDenialBridge(_layout());
      final container = ProviderContainer.test(
        overrides: [denialBridgeProvider.overrideWithValue(bridge)],
      );

      try {
        final controller = container.read(displayLayoutProvider.notifier);
        expect(await controller.ensureLoaded(), isNotNull);

        controller.applyShellConfiguration(
          side: null,
          outputNames: const <String>[],
          systemBarThickness: 54,
          maximizePadding: 17,
        );
        await Future<void>.delayed(Duration.zero);

        expect(bridge.requests, hasLength(1));
        expect(bridge.requests.single.side, SystemBarSide.top);
        expect(bridge.requests.single.monitorIds, <int>[7]);
        expect(bridge.requests.single.systemBarThickness, 54);
        expect(bridge.requests.single.maximizePadding, 17);
      } finally {
        container.dispose();
        bridge.dispose();
        await bridge.close();
      }
    },
  );
}

DisplayLayout _layout() {
  return const DisplayLayout(
    epoch: 1,
    globalOrigin: Offset.zero,
    logicalSize: Size(1920, 1080),
    pixelSize: Size(1920, 1080),
    engineScale: 1,
    tickerMonitorId: 7,
    systemBarMonitorId: 7,
    systemBarMonitorIds: <int>[7],
    systemBarSide: SystemBarSide.top,
    systemBarThickness: 32,
    maximizePadding: 10,
    outputs: <DisplayOutput>[
      DisplayOutput(
        monitorId: 7,
        name: 'eDP-1',
        logicalRect: Rect.fromLTWH(0, 0, 1920, 1080),
        pixelSize: Size(1920, 1080),
        scale: 1,
        refreshRate: 60,
      ),
    ],
  );
}

class _FakeDenialBridge extends DenialBridge {
  _FakeDenialBridge(this.layout);

  final DisplayLayout layout;
  final StreamController<DisplayLayout> _layouts =
      StreamController<DisplayLayout>.broadcast(sync: true);
  final List<
    ({
      SystemBarSide side,
      List<int> monitorIds,
      double systemBarThickness,
      double maximizePadding,
    })
  >
  requests = [];

  @override
  Stream<DisplayLayout> get displayLayouts => _layouts.stream;

  @override
  Future<DisplayLayout?> getDisplayLayout() async => layout;

  @override
  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
    required double systemBarThickness,
    required double maximizePadding,
  }) async {
    requests.add((
      side: side,
      monitorIds: List<int>.of(monitorIds),
      systemBarThickness: systemBarThickness,
      maximizePadding: maximizePadding,
    ));
    return layout;
  }

  Future<void> close() => _layouts.close();
}
