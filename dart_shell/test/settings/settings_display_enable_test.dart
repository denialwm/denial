import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/output_configuration.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_displays_page.dart';
import 'package:denial_dart_shell/src/state/display_brightness.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/output_configuration.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'display toggle disables an output and protects the last enabled output',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            displayLayoutProvider.overrideWithBuild((ref, controller) => null),
            displayBrightnessProvider.overrideWithBuild(
              (ref, controller) => const DisplayBrightnessState(
                levels: <int, double>{},
                loading: <int>{},
              ),
            ),
            outputConfigurationProvider.overrideWithBuild(
              (ref, controller) => const OutputConfigurationState(
                configuration: _configuration,
                draftOutputs: _outputs,
                draftPrimaryOutput: 'DP-1',
                selectedName: 'DP-1',
              ),
            ),
          ],
          child: MaterialApp(
            home: DenialLocalizationScope(
              locale: const Locale('en'),
              child: ShellTheme(
                data: const ShellThemeData(),
                child: const Material(child: SettingsDisplaysPage()),
              ),
            ),
          ),
        ),
      );

      final pageContext = tester.element(find.byType(SettingsDisplaysPage));
      final container = ProviderScope.containerOf(pageContext);
      final firstToggle = find.byKey(settingsDisplayEnabledToggleKey('DP-1'));
      await tester.ensureVisible(firstToggle);
      await tester.tap(firstToggle);
      await tester.pump();

      var state = container.read(outputConfigurationProvider);
      expect(state.draftOutputs.first.enabled, isFalse);
      expect(state.draftOutputs.first.powered, isFalse);
      expect(state.draftPrimaryOutput, isNull);
      expect(state.dirty, isTrue);

      container.read(outputConfigurationProvider.notifier).select('DP-2');
      await tester.pump();

      final lastToggle = tester.widget<SettingsToggle>(
        find.byKey(settingsDisplayEnabledToggleKey('DP-2')),
      );
      expect(lastToggle.value, isTrue);
      expect(lastToggle.enabled, isFalse);

      container
          .read(outputConfigurationProvider.notifier)
          .setEnabled('DP-2', false);
      state = container.read(outputConfigurationProvider);
      expect(state.draftOutputs.last.enabled, isTrue);

      container
          .read(outputConfigurationProvider.notifier)
          .setScrollingLayoutAxis('DP-2', DenialScrollingLayoutAxis.vertical);
      state = container.read(outputConfigurationProvider);
      expect(
        state.draftOutputs.last.scrollingLayoutAxis,
        DenialScrollingLayoutAxis.vertical,
      );
      expect(state.dirty, isTrue);
    },
  );
}

const _mode = DenialOutputMode(
  width: 1920,
  height: 1080,
  refreshMillihz: 60000,
  preferred: true,
);

const _outputs = <DenialOutput>[
  DenialOutput(
    monitorId: 1,
    name: 'DP-1',
    description: 'Desk display',
    connected: true,
    enabled: true,
    powered: true,
    x: 0,
    y: 0,
    logicalWidth: 1920,
    logicalHeight: 1080,
    scale: 1,
    transform: DenialOutputTransform.normal,
    scrollingLayoutAxis: DenialScrollingLayoutAxis.auto,
    adaptiveSyncSupported: false,
    adaptiveSync: false,
    currentMode: _mode,
    modes: <DenialOutputMode>[_mode],
  ),
  DenialOutput(
    monitorId: 2,
    name: 'DP-2',
    description: 'Side display',
    connected: true,
    enabled: true,
    powered: true,
    x: 1920,
    y: 0,
    logicalWidth: 1920,
    logicalHeight: 1080,
    scale: 1,
    transform: DenialOutputTransform.normal,
    scrollingLayoutAxis: DenialScrollingLayoutAxis.auto,
    adaptiveSyncSupported: false,
    adaptiveSync: false,
    currentMode: _mode,
    modes: <DenialOutputMode>[_mode],
  ),
];

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

const _configuration = DenialOutputConfiguration(
  serial: 1,
  capabilities: _capabilities,
  primaryOutput: 'DP-1',
  outputs: _outputs,
);
