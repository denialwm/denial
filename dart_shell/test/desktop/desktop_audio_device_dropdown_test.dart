import 'package:denial_dart_shell/src/desktop/desktop_audio_device_dropdown.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/services/audio_service.dart';
import 'package:denial_dart_shell/src/state/audio_devices.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'dropdown shows unavailable devices but only selects usable outputs',
    (tester) async {
      final selections = <String>[];
      var refreshes = 0;
      const state = AudioDevicesState(
        devices: <AudioOutputDevice>[
          AudioOutputDevice(
            name: 'speaker',
            description: 'Speaker',
            active: true,
            available: true,
          ),
          AudioOutputDevice(
            name: 'headphones',
            description: 'Headphones',
            active: false,
            available: false,
          ),
          AudioOutputDevice(
            name: 'hdmi',
            description: 'HDMI',
            active: false,
            available: true,
          ),
        ],
        loading: false,
        changing: false,
        error: null,
      );

      await tester.pumpWidget(
        ShellTheme(
          data: const ShellThemeData(),
          child: DenialLocalizationScope(
            locale: const Locale('en'),
            child: Center(
              child: SizedBox(
                width: 360,
                child: DashboardAudioDeviceDropdown(
                  state: state,
                  onRefresh: () => refreshes += 1,
                  onSelected: selections.add,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Speaker'), findsOneWidget);
      expect(find.text('Headphones'), findsNothing);

      await tester.tap(find.byKey(dashboardAudioDeviceDropdownButtonKey));
      await tester.pumpAndSettle();

      expect(refreshes, 1);
      expect(find.text('Headphones (not connected)'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(dashboardAudioDeviceOptionKey('headphones')))
            .height,
        tester
            .getSize(find.byKey(dashboardAudioDeviceOptionKey('speaker')))
            .height,
      );

      await tester.tap(find.byKey(dashboardAudioDeviceOptionKey('headphones')));
      await tester.pump();
      expect(selections, isEmpty);
      expect(find.text('Headphones (not connected)'), findsOneWidget);

      await tester.tap(find.byKey(dashboardAudioDeviceOptionKey('hdmi')));
      await tester.pumpAndSettle();

      expect(selections, <String>['hdmi']);
      expect(find.text('Headphones'), findsNothing);
    },
  );
}
