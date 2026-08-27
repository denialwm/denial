import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/services/desktop_power_modes_service.dart';
import 'package:denial_dart_shell/src/services/lact_service.dart';
import 'package:denial_dart_shell/src/services/power_profile_service.dart';
import 'package:denial_dart_shell/src/state/desktop_power_modes.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'dashboard keeps its card gap and caps Bluetooth when power modes hide',
    (tester) async {
      const volumeKey = ValueKey<String>('test-dashboard-volume');
      const bluetoothKey = ValueKey<String>('test-dashboard-bluetooth');

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 470,
            height: 500,
            child: DesktopDashboardCardLayout(
              volume: SizedBox(key: volumeKey, height: 100),
              powerModes: SizedBox.shrink(),
              bluetooth: SizedBox.expand(key: bluetoothKey),
            ),
          ),
        ),
      );

      final volumeRect = tester.getRect(find.byKey(volumeKey));
      final bluetoothRect = tester.getRect(find.byKey(bluetoothKey));
      expect(bluetoothRect.top - volumeRect.bottom, 12);
      expect(bluetoothRect.height, desktopDashboardBluetoothMaxHeight);
    },
  );

  testWidgets('hides the section when no power-mode source is available', (
    tester,
  ) async {
    await _pumpSection(tester, DesktopPowerModesState.initial());

    expect(find.text('Power modes'), findsNothing);
  });

  testWidgets(
    'hides the section when the primary system profile is not editable',
    (tester) async {
      await _pumpSection(
        tester,
        _state(systemAvailable: false, pboAvailable: true, gpuAvailable: true),
      );

      expect(find.text('Power modes'), findsNothing);
      expect(find.text('PBO'), findsNothing);
      expect(find.text('GPU'), findsNothing);
    },
  );

  testWidgets('only renders rows backed by available sources', (tester) async {
    await _pumpSection(
      tester,
      _state(systemAvailable: true, pboAvailable: false, gpuAvailable: true),
    );

    expect(find.text('Power modes'), findsOneWidget);
    expect(find.text('System profile'), findsOneWidget);
    expect(find.text('PBO'), findsNothing);
    expect(find.text('GPU'), findsOneWidget);
    expect(find.textContaining('Not available'), findsNothing);
  });
}

DesktopPowerModesState _state({
  required bool systemAvailable,
  required bool pboAvailable,
  required bool gpuAvailable,
}) {
  return DesktopPowerModesState(
    systemAvailable: systemAvailable,
    systemProfile: PowerProfile.balanced,
    pboAvailable: pboAvailable,
    pboProfile: pboAvailable ? DesktopPboProfile.balanced : null,
    gpuAvailable: gpuAvailable,
    gpuPerformancePreset: gpuAvailable ? LactPerformancePreset.automatic : null,
    refreshing: false,
    systemChanging: false,
    pboChanging: false,
    gpuChanging: false,
  );
}

Future<void> _pumpSection(
  WidgetTester tester,
  DesktopPowerModesState state,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopPowerModesProvider.overrideWith(
          () => _FixedDesktopPowerModesController(state),
        ),
      ],
      child: const DenialLocalizationScope(
        locale: Locale('en'),
        child: ShellTheme(
          data: ShellThemeData(),
          child: SizedBox(width: 470, child: DesktopPowerModesSection()),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _FixedDesktopPowerModesController extends DesktopPowerModesController {
  _FixedDesktopPowerModesController(this.fixedState);

  final DesktopPowerModesState fixedState;

  @override
  DesktopPowerModesState build() => fixedState;
}
