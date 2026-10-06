import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/desktop/desktop_system_bar.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/battery_status.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/services/media_player_service.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';
import 'package:denial_dart_shell/src/state/system_tray.dart';
import 'package:denial_dart_shell/src/theme/glass_configuration.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_accent.dart';
import 'package:denial_dart_shell/src/widgets/shell_backdrop_blur.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('overview barrier leaves system-bar controls clickable', (
    tester,
  ) async {
    var barrierTaps = 0;
    var controlTaps = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 200,
            child: DesktopOverviewInputLayer(
              active: true,
              onBarrierTap: (_) => barrierTaps += 1,
              foregroundControls: <Widget>[
                Positioned(
                  left: 20,
                  top: 12,
                  width: 80,
                  height: 32,
                  child: GestureDetector(
                    key: const ValueKey<String>('system-bar-control'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => controlTaps += 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(40, 28));
    expect(controlTaps, 1);
    expect(barrierTaps, 0);

    await tester.tapAt(const Offset(200, 150));
    expect(controlTaps, 1);
    expect(barrierTaps, 1);
  });

  testWidgets('horizontal workspace indicator does not fill the bar width', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 800,
            height: 48,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Center(
                  child: DesktopSystemBarIndicatorSlot(
                    horizontal: true,
                    child: _ExpandingIndicatorCard(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(_cardKey)), const Size(180, 48));
  });

  testWidgets('vertical workspace indicator does not fill the bar height', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 48,
            height: 600,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Center(
                  child: DesktopSystemBarIndicatorSlot(
                    horizontal: false,
                    child: _ExpandingIndicatorCard(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(_cardKey)), const Size(48, 28));
  });

  testWidgets('scaled system-bar cards preserve the rounded clip backdrop', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          batteryProvider.overrideWithBuild((_, _) => BatteryStatus.unknown),
          clockProvider.overrideWith(
            (_) => Stream.value(DateTime(2026, 9, 17, 12, 34)),
          ),
          cpuUsageProvider.overrideWithValue(
            const LoadSeries(current: 0.42, history: <double>[0.2, 0.42]),
          ),
          gpuUsageProvider.overrideWithValue(const <GpuLoad>[
            GpuLoad(
              id: 'gpu0',
              label: 'GPU',
              series: LoadSeries(current: 0.31, history: <double>[0.18, 0.31]),
            ),
          ]),
          mediaPlaybackProvider.overrideWith(
            (_) => Stream.value(MprisPlaybackState.unavailable()),
          ),
          shellAccentProvider.overrideWithValue(
            WallpaperAccent.resolvedFallback,
          ),
          shellSettingsProvider.overrideWithBuild(
            (_, _) => const ShellSettings(),
          ),
          systemTrayProvider.overrideWithBuild((_, _) => const []),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: ShellTheme(
            data: const ShellThemeData(
              transparencyMode: ShellTransparencyMode.glass,
            ),
            child: const SizedBox(
              width: 800,
              height: 33,
              child: DesktopSystemBar(
                monitorId: 1,
                side: SystemBarSide.top,
                onOpenPowerSettings: _ignore,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final cards = tester.widgetList<ShellBackdropBlur>(
      find.byType(ShellBackdropBlur),
    );
    expect(cards, hasLength(3));
    expect(cards.every((card) => card.blendMode == BlendMode.srcOver), isTrue);
  });
}

void _ignore() {}

const _cardKey = ValueKey<String>('workspace-indicator-card');

class _ExpandingIndicatorCard extends StatelessWidget {
  const _ExpandingIndicatorCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: _cardKey,
      alignment: Alignment.center,
      child: const SizedBox(width: 180, height: 28),
    );
  }
}
