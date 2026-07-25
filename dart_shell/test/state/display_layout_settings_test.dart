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
    'persisted shell metrics apply before the native layout is exposed',
    () async {
      final bridge = _LayoutBridge(_layout);
      final container = ProviderContainer.test(
        overrides: [denialBridgeProvider.overrideWithValue(bridge)],
      );
      addTearDown(container.dispose);
      final controller = container.read(displayLayoutProvider.notifier);

      controller.applyShellConfiguration(
        side: SystemBarSide.right,
        outputNames: const <String>['secondary'],
        systemBarThickness: 52,
        maximizePadding: 20,
      );
      final loaded = await controller.ensureLoaded();

      expect(loaded, isNotNull);
      expect(loaded!.systemBarSide, SystemBarSide.right);
      expect(loaded.effectiveSystemBarMonitorIds, const <int>[11]);
      expect(loaded.systemBarThickness, 52);
      expect(loaded.maximizePadding, 20);
      expect(bridge.configurations, hasLength(1));
      expect(bridge.configurations.single.$1, SystemBarSide.right);
      expect(bridge.configurations.single.$2, const <int>[11]);

      final exposed = container.read(displayLayoutProvider);
      controller.applyShellConfiguration(
        side: SystemBarSide.right,
        outputNames: const <String>['secondary'],
        systemBarThickness: 52,
        maximizePadding: 20,
      );

      expect(identical(container.read(displayLayoutProvider), exposed), isTrue);
      expect(bridge.configurations, hasLength(1));
    },
  );
}

class _LayoutBridge extends DenialBridge {
  _LayoutBridge(this.layout);

  final DisplayLayout layout;
  final List<(SystemBarSide, List<int>)> configurations = [];

  @override
  Future<DisplayLayout?> getDisplayLayout() async => layout;

  @override
  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
  }) async {
    configurations.add((side, List<int>.of(monitorIds)));
    return layout.copyWithSystemBar(side: side, monitorIds: monitorIds);
  }
}

const _layout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(2000, 800),
  pixelSize: Size(2000, 800),
  engineScale: 1,
  tickerMonitorId: 22,
  systemBarMonitorId: 22,
  systemBarSide: SystemBarSide.left,
  systemBarThickness: 32,
  maximizePadding: 10,
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
