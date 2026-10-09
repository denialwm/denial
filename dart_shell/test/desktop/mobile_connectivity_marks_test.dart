import 'dart:async';

import 'package:denial_desktop/src/widgets/shade/status_glyphs.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// No real network services, SIM reads, or device/UI events are used.
class _ConnectedWifi extends NetworkConnectivityController {
  @override
  NetworkConnectivityState build() =>
      NetworkConnectivityState.initial().copyWith(
        snapshot: NetworkSnapshot(
          serviceAvailable: true,
          wifiDeviceAvailable: true,
          wirelessHardwareEnabled: true,
          wirelessEnabled: true,
          status: NetworkConnectivityStatus.online,
          networks: [
            WifiNetwork(
              ssid: 'test',
              ssidBytes: [116, 101, 115, 116],
              security: WifiSecurity.open,
              strength: 80,
              frequency: 2400,
              devicePath: '/wifi/0',
              networkPath: '/ap/0',
              savedNetworkPath: null,
              connected: true,
              available: true,
            ),
          ],
          activeNetworkPath: '/ap/0',
          devicePath: '/wifi/0',
          lastScan: 0,
          radioPermission: NetworkPermission.allowed,
          controlPermission: NetworkPermission.allowed,
          modifyPermission: NetworkPermission.allowed,
        ),
      );
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('SIM controls icon, gap and semantics at scale $scale', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);
      final updates = StreamController<MobileNetworkSnapshot>();
      addTearDown(updates.close);
      final l10n = AppLocalizationsEn();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            networkConnectivityProvider.overrideWith(_ConnectedWifi.new),
            mobileNetworkProvider.overrideWith((ref) => updates.stream),
          ],
          child: DenialLocalizationScope(
            locale: const Locale('en'),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(child: MobileConnectivityMarks(scale: scale)),
            ),
          ),
        ),
      );
      await tester.pump();

      void unavailable({bool disconnected = false}) {
        expect(find.byType(SignalGlyph), findsOneWidget);
        expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);
        expect(
          tester.widget<SignalGlyph>(find.byType(SignalGlyph)).active,
          isFalse,
        );
        expect(
          find.bySemanticsLabel(
            disconnected ? l10n.mobileDisconnected : l10n.mobileUnavailable,
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(l10n.mobileConnected), findsNothing);
        expect(
          tester.getSize(find.byType(MobileConnectivityMarks)).width,
          closeTo(64 * scale, 0.001),
        );
        // Wi-Fi never turns an unavailable cellular icon into a working one.
        expect(find.byIcon(Icons.wifi_rounded), findsOneWidget);
      }

      Future<void> emit(MobileNetworkSnapshot snapshot) async {
        updates.add(snapshot);
        await tester.pump();
        await tester.pump();
      }

      unavailable(); // Loading is unknown, not confirmed absence.
      updates.addError(StateError('Discovery unavailable'));
      await tester.pump();
      await tester.pump();
      unavailable();

      await emit(
        const MobileNetworkSnapshot(simPresence: MobileSimPresence.absent),
      );
      expect(find.byType(SignalGlyph), findsNothing);
      expect(find.byIcon(Icons.priority_high_rounded), findsNothing);
      expect(find.bySemanticsLabel(l10n.mobileDisconnected), findsNothing);
      expect(find.bySemanticsLabel(l10n.mobileConnected), findsNothing);
      expect(find.bySemanticsLabel(l10n.mobileUnavailable), findsNothing);
      expect(
        tester.getSize(find.byType(MobileConnectivityMarks)).width,
        closeTo(20 * scale, 0.001),
      ); // No cellular gap remains.
      expect(find.byIcon(Icons.wifi_rounded), findsOneWidget);

      for (final snapshot in const [
        MobileNetworkSnapshot(simPresence: MobileSimPresence.unknown),
        MobileNetworkSnapshot(
          simPresence: MobileSimPresence.present,
          unlockRequired: 2,
        ),
        MobileNetworkSnapshot(simPresence: MobileSimPresence.present),
        MobileNetworkSnapshot(
          simPresence: MobileSimPresence.present,
          registered: true,
          connected: true,
          managerAvailable: true,
          enabled: false,
          hardwareEnabled: true,
        ),
        MobileNetworkSnapshot(
          simPresence: MobileSimPresence.present,
          registered: true,
          connected: true,
          managerAvailable: false,
        ),
      ]) {
        await emit(snapshot);
        unavailable(disconnected: snapshot.managerAvailable);
      }

      const working = MobileNetworkSnapshot(
        modemPath: '/modem/0',
        simPresence: MobileSimPresence.present,
        registered: true,
        connected: true,
        managerAvailable: true,
        enabled: true,
        hardwareEnabled: true,
        strength: 75,
      );
      void connected() {
        expect(find.byType(SignalGlyph), findsOneWidget);
        expect(
          tester.widget<SignalGlyph>(find.byType(SignalGlyph)).active,
          isTrue,
        );
        expect(find.byIcon(Icons.priority_high_rounded), findsNothing);
        expect(find.bySemanticsLabel(l10n.mobileConnected), findsOneWidget);
        expect(find.bySemanticsLabel(l10n.mobileDisconnected), findsNothing);
        expect(find.bySemanticsLabel(l10n.mobileUnavailable), findsNothing);
        expect(
          tester.getSize(find.byType(MobileConnectivityMarks)).width,
          closeTo(52 * scale, 0.001),
        );
      }

      await emit(working);
      connected();
      updates.addError(StateError('Backend lost after working'));
      await tester.pump();
      await tester.pump();
      unavailable();
      await emit(working);
      connected();
      await emit(working.unavailable());
      unavailable();
      await emit(working);
      connected();
    });
  }
}
