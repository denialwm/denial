import 'package:denial_dart_shell/src/services/desktop_power_modes_service.dart';
import 'package:denial_dart_shell/src/services/lact_service.dart';
import 'package:denial_dart_shell/src/services/power_profile_service.dart';
import 'package:denial_dart_shell/src/state/desktop_power_modes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('controller refreshes and applies the AMD LACT preset', () async {
    final service = _FakeDesktopPowerModesService();
    final container = ProviderContainer.test(
      overrides: [desktopPowerModesServiceProvider.overrideWithValue(service)],
    );
    final controller = container.read(desktopPowerModesProvider.notifier);

    await controller.refresh();

    var state = container.read(desktopPowerModesProvider);
    expect(state.gpuAvailable, isTrue);
    expect(state.gpuPerformancePreset, LactPerformancePreset.low);

    await controller.selectGpuPerformancePreset(
      LactPerformancePreset.automatic,
    );

    state = container.read(desktopPowerModesProvider);
    expect(service.appliedGpuPreset, LactPerformancePreset.automatic);
    expect(state.gpuPerformancePreset, LactPerformancePreset.automatic);
    expect(state.gpuChanging, isFalse);
    expect(state.error, isNull);
  });
}

class _FakeDesktopPowerModesService extends DesktopPowerModesService {
  _FakeDesktopPowerModesService()
    : super(environment: const <String, String>{});

  String? appliedGpuPreset;

  @override
  Future<DesktopPowerModesSnapshot> readSnapshot() async {
    return const DesktopPowerModesSnapshot(
      systemAvailable: true,
      systemProfile: PowerProfile.balanced,
      pboAvailable: true,
      pboProfile: DesktopPboProfile.balanced,
      gpuAvailable: true,
      gpuPerformancePreset: LactPerformancePreset.low,
    );
  }

  @override
  Future<void> applyGpuPerformancePreset(String preset) async {
    appliedGpuPreset = preset;
  }

  @override
  Future<void> dispose() async {}
}
