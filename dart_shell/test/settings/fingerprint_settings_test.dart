import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/fingerprint/fingerprint_service.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_fingerprint_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_navigation.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('password gate hides enrolled data and enrollment controls', (
    tester,
  ) async {
    final session = FingerprintSettingsSession()
      ..fingers = ['right-index-finger'];
    addTearDown(session.dispose);
    await tester.pumpWidget(_harness(const SettingsFingerprintPage(), session));
    expect(find.text('Sudo password'), findsOneWidget);
    expect(find.text('Right index finger'), findsNothing);
    expect(find.text('Add fingerprint'), findsNothing);
    expect(find.text('Enroll fingerprint'), findsNothing);
    session.handleEvent({
      'event': 'ready',
      'fingers': ['right-index-finger'],
    });
    await tester.pump();
    expect(session.authorized, isFalse);
    expect(find.text('Right index finger'), findsNothing);
    // Simulate only the trusted helper result following an active request.
    session.authenticating = true;
    session.handleEvent({
      'event': 'ready',
      'fingers': ['right-index-finger'],
    });
    await tester.pump();
    expect(find.text('Sudo password'), findsNothing);
    expect(find.text('Right index finger'), findsOneWidget);
    expect(find.text('Add fingerprint'), findsOneWidget);
    session.close();
    await tester.pump();
    expect(find.text('Sudo password'), findsOneWidget);
    expect(find.text('Right index finger'), findsNothing);
  });

  testWidgets('empty enrollment state offers selection and enrollment', (
    tester,
  ) async {
    final session = FingerprintSettingsSession()..authenticating = true;
    session.handleEvent({'event': 'ready', 'fingers': <String>[]});
    addTearDown(session.dispose);
    await tester.pumpWidget(_harness(const SettingsFingerprintPage(), session));
    expect(find.text('No fingerprints enrolled'), findsOneWidget);
    expect(find.text('Enroll fingerprint'), findsOneWidget);
    session.enroll('left-thumb');
    session.handleEvent({
      'event': 'enrollment',
      'status': 'enroll-stage-passed',
      'completed': 2,
      'total': 9,
    });
    await tester.pump();
    expect(find.text('2 of 9 scans'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    session.handleEvent({
      'event': 'enrollment',
      'status': 'enroll-completed',
      'completed': 9,
      'total': 9,
    });
    session.handleEvent({
      'event': 'ready',
      'fingers': ['left-thumb'],
    });
    await tester.pump();
    expect(find.text('No fingerprints enrolled'), findsNothing);
    expect(find.text('Left thumb'), findsOneWidget);
    expect(find.text('Add fingerprint'), findsOneWidget);
  });

  testWidgets('navigation only includes fingerprint with a detected reader', (
    tester,
  ) async {
    final session = FingerprintSettingsSession();
    addTearDown(session.dispose);
    Widget navigation(bool detected) => SettingsNavigation(
      selected: SettingsPageId.appearance,
      onSelected: (_) {},
      compact: false,
      showFingerprint: detected,
    );
    await tester.pumpWidget(_harness(navigation(false), session));
    expect(
      find.byKey(const ValueKey(SettingsPageId.fingerprint)),
      findsNothing,
    );
    await tester.pumpWidget(_harness(navigation(true), session));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey(SettingsPageId.fingerprint)),
      150,
    );
    expect(find.text('Fingerprint'), findsOneWidget);
  });
}

Widget _harness(Widget child, FingerprintSettingsSession session) =>
    ProviderScope(
      overrides: [fingerprintSessionProvider.overrideWithValue(session)],
      child: MaterialApp(
        home: DenialLocalizationScope(
          locale: const Locale('en'),
          child: ShellTheme(
            data: const ShellThemeData(),
            child: Material(child: child),
          ),
        ),
      ),
    );
