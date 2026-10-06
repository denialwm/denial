import 'package:denial_dart_shell/src/models/output_configuration.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/state/output_configuration.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('expiry refresh waits for the post-rollback snapshot', () async {
    final bridge = _OutputBridge(<DenialOutputConfiguration>[
      _configuration(serial: 10, scale: 2, pendingToken: 11),
      _configuration(serial: 10, scale: 2, pendingToken: 11),
      _configuration(serial: 12, scale: 1),
    ]);
    final container = ProviderContainer.test(
      overrides: [denialBridgeProvider.overrideWithValue(bridge)],
    );

    try {
      container.read(outputConfigurationProvider);
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(outputConfigurationProvider)
            .configuration
            ?.pendingConfirmation
            ?.token,
        11,
      );

      await container
          .read(outputConfigurationProvider.notifier)
          .refreshAfterConfirmationExpiry(11);

      final state = container.read(outputConfigurationProvider);
      expect(bridge.reads, 3);
      expect(state.configuration?.serial, 12);
      expect(state.draftOutputs.single.scale, 1);
      expect(state.configuration?.pendingConfirmation, isNull);
      expect(state.loading, isFalse);
      expect(state.dirty, isFalse);
    } finally {
      container.dispose();
      bridge.dispose();
    }
  });
}

const _capabilities = DenialOutputCapabilities(
  apply: true,
  enable: true,
  position: true,
  mode: true,
  scale: true,
  transform: true,
  scrollingLayoutAxis: true,
  adaptiveSync: true,
  persistent: true,
);

const _mode = DenialOutputMode(
  width: 1920,
  height: 1080,
  refreshMillihz: 60000,
  preferred: true,
);

DenialOutputConfiguration _configuration({
  required int serial,
  required double scale,
  int? pendingToken,
}) {
  return DenialOutputConfiguration(
    serial: serial,
    capabilities: _capabilities,
    outputs: <DenialOutput>[
      DenialOutput(
        name: 'DP-1',
        description: 'Display',
        connected: true,
        enabled: true,
        powered: true,
        x: 0,
        y: 0,
        logicalWidth: (1920 / scale).round(),
        logicalHeight: (1080 / scale).round(),
        scale: scale,
        transform: DenialOutputTransform.normal,
        scrollingLayoutAxis: DenialScrollingLayoutAxis.auto,
        adaptiveSyncSupported: false,
        adaptiveSync: false,
        currentMode: _mode,
        modes: const <DenialOutputMode>[_mode],
      ),
    ],
    pendingConfirmation: pendingToken == null
        ? null
        : DenialOutputConfirmation(
            token: pendingToken,
            deadlineUnixMilliseconds: 1,
          ),
  );
}

class _OutputBridge extends DenialBridge {
  _OutputBridge(this.configurations);

  final List<DenialOutputConfiguration> configurations;
  var reads = 0;

  @override
  Future<DenialOutputConfiguration> readOutputConfiguration() async {
    final index = reads.clamp(0, configurations.length - 1);
    reads += 1;
    return configurations[index];
  }
}
