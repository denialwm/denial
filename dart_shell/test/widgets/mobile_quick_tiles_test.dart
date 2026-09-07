import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/shade/quick_settings_tiles.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('phone controls fit narrow widths and retain every action', (
    tester,
  ) async {
    var toggles = 0;
    var details = 0;
    for (final width in [280.0, 360.0, 480.0]) {
      await tester.pumpWidget(
        DenialLocalizationScope(
          locale: const Locale('en'),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(),
              child: ShellTheme(
                data: const ShellThemeData(),
                child: Center(
                  child: SizedBox(
                    width: width,
                    child: QuickSettingsTiles(
                      wifi: true,
                      wifiSubtitle: 'Connected network',
                      wifiEnabled: true,
                      wifiBusy: false,
                      bluetooth: true,
                      bluetoothSubtitle: 'Connected device',
                      bluetoothEnabled: true,
                      bluetoothBusy: false,
                      rotationLock: true,
                      dnd: false,
                      dndReady: true,
                      profile: 'balanced',
                      onToggleWifi: () => toggles++,
                      onOpenWifi: () => details++,
                      onToggleBluetooth: () => toggles++,
                      onOpenBluetooth: () => details++,
                      onToggleRotation: () => toggles++,
                      onToggleDnd: () => toggles++,
                      onCycleProfile: () => toggles++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(QuickTile), findsNWidgets(5));
      for (final element in find.byType(QuickTile).evaluate()) {
        final tile = element.widget as QuickTile;
        final target = find.byWidget(tile);
        await tester.tapAt(
          tile.wide
              ? tester.getTopLeft(target) + const Offset(30, 90)
              : tester.getCenter(target),
        );
      }
      for (final icon in find.byIcon(Icons.chevron_right_rounded).evaluate()) {
        await tester.tap(find.byWidget(icon.widget));
      }
    }
    expect(toggles, 15);
    expect(details, 6);
  });
}
