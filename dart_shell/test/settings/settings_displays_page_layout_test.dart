import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/output_configuration.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_displays_page.dart';
import 'package:denial_dart_shell/src/state/display_brightness.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/output_configuration.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unsupported software dimming keeps the display page bounded', (
    tester,
  ) async {
    final layoutOutputs = <DisplayOutput>[
      DisplayOutput(
        monitorId: 438,
        name: 'DP-4',
        logicalRect: const Rect.fromLTWH(0, 563, 2560, 1440),
        pixelSize: const Size(2560, 1440),
        scale: 1,
        refreshRate: 240.001,
      ),
      DisplayOutput(
        monitorId: 448,
        name: 'DP-5',
        logicalRect: const Rect.fromLTWH(2560, 0, 1440, 2560),
        pixelSize: const Size(2560, 1440),
        scale: 1,
        refreshRate: 143.973,
      ),
    ];
    final layout = DisplayLayout(
      epoch: 1,
      globalOrigin: Offset.zero,
      logicalSize: const Size(4000, 2560),
      pixelSize: const Size(4000, 2560),
      engineScale: 1,
      tickerMonitorId: layoutOutputs.first.monitorId,
      systemBarMonitorId: layoutOutputs.first.monitorId,
      systemBarSide: SystemBarSide.top,
      outputs: layoutOutputs,
    );
    const landscapeMode = DenialOutputMode(
      width: 2560,
      height: 1440,
      refreshMillihz: 240001,
      preferred: false,
    );
    const portraitMode = DenialOutputMode(
      width: 2560,
      height: 1440,
      refreshMillihz: 143973,
      preferred: true,
    );
    const outputs = <DenialOutput>[
      DenialOutput(
        monitorId: 438,
        name: 'DP-4',
        description: 'DP-4',
        connected: true,
        enabled: true,
        powered: true,
        x: 0,
        y: 563,
        logicalWidth: 2560,
        logicalHeight: 1440,
        scale: 1,
        transform: DenialOutputTransform.normal,
        scrollingLayoutAxis: DenialScrollingLayoutAxis.auto,
        adaptiveSyncSupported: true,
        adaptiveSync: false,
        currentMode: landscapeMode,
        modes: <DenialOutputMode>[landscapeMode],
      ),
      DenialOutput(
        monitorId: 448,
        name: 'DP-5',
        description: 'DP-5',
        connected: true,
        enabled: true,
        powered: true,
        x: 2560,
        y: 0,
        logicalWidth: 1440,
        logicalHeight: 2560,
        scale: 1,
        transform: DenialOutputTransform.rotate270,
        scrollingLayoutAxis: DenialScrollingLayoutAxis.auto,
        adaptiveSyncSupported: true,
        adaptiveSync: true,
        currentMode: portraitMode,
        modes: <DenialOutputMode>[portraitMode],
      ),
    ];
    const capabilities = DenialOutputCapabilities(
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
    const configuration = DenialOutputConfiguration(
      serial: 1,
      capabilities: capabilities,
      primaryOutput: 'DP-4',
      outputs: outputs,
    );
    const brightness = DisplayBrightnessState(
      levels: <int, double>{438: 0.72, 448: 0.68},
      loading: <int>{},
    );

    Widget buildPage(DisplayBrightnessState state, Key scopeKey) {
      return ProviderScope(
        key: scopeKey,
        overrides: [
          displayLayoutProvider.overrideWithBuild((ref, controller) => layout),
          displayBrightnessProvider.overrideWithBuild(
            (ref, controller) => state,
          ),
          outputConfigurationProvider.overrideWithBuild(
            (ref, controller) => const OutputConfigurationState(
              configuration: configuration,
              draftOutputs: outputs,
              draftPrimaryOutput: 'DP-4',
              selectedName: 'DP-4',
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
      );
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in <double>[360, 800]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pumpWidget(buildPage(brightness, ValueKey<double>(width)));

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(settingsMonitorCanvasKey)).height, 360);
      expect(
        find.byKey(settingsScrollingLayoutAxisSelectorKey('DP-4')),
        findsOneWidget,
      );
      final cardSize = tester.getSize(
        find.byKey(settingsDisplayBrightnessCardKey),
      );
      expect(cardSize.height.isFinite, isTrue);
      expect(cardSize.height, lessThan(300));

      for (final output in layoutOutputs) {
        final hardwareSliderSize = tester.getSize(
          find.byKey(settingsHardwareBrightnessSliderKey(output.monitorId)),
        );
        expect(hardwareSliderSize.height.isFinite, isTrue);
        expect(hardwareSliderSize.height, lessThan(100));
        expect(
          find.byKey(settingsSoftwareDimmingSliderKey(output.monitorId)),
          findsNothing,
        );
      }
    }
  });
}
