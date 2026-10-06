import 'dart:async';

import 'package:denial_dart_shell/src/core/shell_secure_stage.dart';
import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/services/mobile_network_service.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/lock/sim_pin_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'fingerprint unlock retains SIM prompt and input capture until explicit resolution',
    (tester) async {
      final service = _PinService();
      final locked = ValueNotifier(true);
      addTearDown(locked.dispose);
      final entry = OverlayEntry(
        builder: (_) => FocusScope(
          child: ValueListenableBuilder<bool>(
            valueListenable: locked,
            builder: (context, isLocked, _) => MobileSimPromptStage(
              child: UnlockTransitionHost(
                locked: isLocked,
                lockLayerVisible: isLocked,
                fingerprintBlack: true,
                onUnlockComplete: () {},
                scene: const SizedBox(),
                chrome: const SizedBox(),
                backdrop: const SizedBox(),
                lockLayerBuilder: (_) =>
                    const SizedBox(key: ValueKey('device-lock')),
              ),
            ),
          ),
        ),
      );
      addTearDown(service.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mobileNetworkServiceProvider.overrideWithValue(service),
            mobileNetworkProvider.overrideWith(
              (ref) => Stream.value(
                const MobileNetworkSnapshot(
                  modemPath: '/modem',
                  simPath: '/sim',
                  unlockRequired: 2,
                  pinRetries: 3,
                ),
              ),
            ),
          ],
          child: DenialLocalizationScope(
            locale: const Locale('en'),
            child: MediaQuery(
              data: const MediaQueryData(size: Size(400, 800)),
              child: ShellTheme(
                data: const ShellThemeData(),
                child: Overlay(initialEntries: [entry]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.calls, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '1234');
      await tester.pump();
      final pinController = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SimPinPanel)),
      );
      locked.value = false;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-lock')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(pinController),
      );
      expect(pinController!.text, '1234');
      expect(
        container.read(shellInteractionRegistryProvider).capturesFullScene,
        isTrue,
      );
      expect(
        container.read(shellInteractionRegistryProvider).capturesKeyboard,
        isTrue,
      );
      expect(service.calls, 0);

      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(service.calls, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      service.pending.completeError(StateError('failed'));
      await tester.pumpAndSettle();
      expect(service.calls, 1);
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(
        container.read(shellInteractionRegistryProvider).capturesFullScene,
        isFalse,
      );
      expect(service.calls, 1);
      expect(tester.takeException(), isNull);
      entry.remove();
      entry.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _PinService extends MobileNetworkService {
  int calls = 0;
  final pending = Completer<void>();
  @override
  Future<void> sendPin(String simPath, String pin) {
    expect(simPath, '/sim');
    expect(pin, '1234');
    calls++;
    return pending.future;
  }
}
