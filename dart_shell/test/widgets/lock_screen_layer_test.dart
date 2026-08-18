import 'dart:async';

import 'package:denial_dart_shell/src/input/input_layout.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_snapshot.dart';
import 'package:denial_dart_shell/src/models/shell_power_status.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/launcher/widgets/home_tiles.dart';
import 'package:denial_dart_shell/src/platform/authentication_protocol.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/authentication_service.dart';
import 'package:denial_dart_shell/src/services/power_status_service.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/authentication.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_profile.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';
import 'package:denial_dart_shell/src/widgets/lock/lock_screen_layer.dart';
import 'package:denial_dart_shell/src/widgets/shell_wallpaper.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('swipe requests native authentication but cannot unlock', (
    tester,
  ) async {
    final service = _FakeAuthenticationService();
    final bridge = _LayoutBridge(_singleOutputLayout);
    addTearDown(() {
      service.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(
      _host(service: service, bridge: bridge, profile: ShellProfile.mobile),
    );
    service.emit(_state(locked: true));
    await tester.pump();

    await tester.drag(find.byType(LockScreenLayer), const Offset(0, -360));
    await tester.pump(const Duration(milliseconds: 240));

    expect(service.beginCount, 1);
    expect(service.lockCount, 0);
    expect(
      tester
          .widgetList<LockScreenLayer>(find.byType(LockScreenLayer))
          .single
          .unlockProgress
          .value,
      0,
    );
    expect(find.bySemanticsLabel('Desktop lock screen'), findsOneWidget);
  });

  testWidgets('credential is one-shot and never enters authentication state', (
    tester,
  ) async {
    final service = _FakeAuthenticationService(expectedResponse: 'one-shot');
    final bridge = _LayoutBridge(_singleOutputLayout);
    addTearDown(() {
      service.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(_host(service: service, bridge: bridge));
    service.emit(_state(locked: true));
    service.emit(_prompt(attemptId: 8, sequence: 3));
    await tester.pump();

    final editor = find.byType(EditableText);
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'one-shot');
    await tester.tap(find.text('Unlock'));
    await tester.pump();

    expect(service.responseCount, 1);
    expect(service.responseMatched, isTrue);
    expect(tester.widget<EditableText>(editor).controller.text, isEmpty);
    final state = ProviderScope.containerOf(
      tester.element(find.byType(LockScreenLayer)),
    ).read(authenticationProvider);
    expect(<Object?>[
      state.prompt?.message,
      state.resultMessage,
      state.statusMessage,
    ], isNot(contains('one-shot')));
    expect(state.locked, isTrue);
  });

  testWidgets('mobile authentication has no private on-screen keyboard', (
    tester,
  ) async {
    final service = _FakeAuthenticationService();
    final bridge = _LayoutBridge(_singleOutputLayout);
    addTearDown(() {
      service.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(
      _host(service: service, bridge: bridge, profile: ShellProfile.mobile),
    );
    service.emit(_state(locked: true));
    service.emit(_prompt(attemptId: 9, sequence: 4));
    await tester.pump();

    expect(find.byType(EditableText), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_rounded), findsNothing);
  });

  testWidgets('mobile authentication stays above the system keyboard', (
    tester,
  ) async {
    final service = _FakeAuthenticationService();
    final bridge = _LayoutBridge(_singleOutputLayout);
    addTearDown(() {
      service.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(
      _host(service: service, bridge: bridge, profile: ShellProfile.mobile),
    );
    service.emit(_state(locked: true));
    service.emit(_prompt(attemptId: 10, sequence: 5));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LockScreenLayer)),
    );
    container.read(shellControllerProvider.notifier).openEdgePanel();
    await tester.pump();

    final keyboardTop =
        _singleOutputLayout.logicalSize.height -
        ShellMetrics.edgePanelHeight(_singleOutputLayout.logicalSize);
    final panel = find.byKey(
      const ValueKey<String>('mobile-lock-authentication-panel'),
    );
    final editor = find.byKey(
      const ValueKey<String>('lock-authentication-field'),
    );
    expect(panel, findsOneWidget);
    expect(editor, findsOneWidget);
    expect(tester.getBottomLeft(panel).dy, lessThanOrEqualTo(keyboardTop));
    expect(tester.getBottomLeft(editor).dy, lessThan(keyboardTop));
  });

  testWidgets(
    'every output is covered and only the main output authenticates',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 600);
      addTearDown(tester.view.reset);
      final service = _FakeAuthenticationService();
      final bridge = _LayoutBridge(_dualOutputLayout);
      addTearDown(() {
        service.dispose();
        bridge.dispose();
      });

      await tester.pumpWidget(_host(service: service, bridge: bridge));
      await tester.pump();
      service.emit(_state(locked: true));
      service.emit(_prompt(attemptId: 19, sequence: 5));
      await tester.pump();

      final mainPane = find.byKey(const ValueKey<int>(11));
      final secondaryPane = find.byKey(const ValueKey<int>(22));
      expect(mainPane, findsOneWidget);
      expect(secondaryPane, findsOneWidget);
      expect(tester.getRect(mainPane), const Rect.fromLTWH(0, 0, 800, 600));
      expect(
        tester.getRect(secondaryPane),
        const Rect.fromLTWH(800, 0, 800, 600),
      );
      expect(find.byType(EditableText), findsOneWidget);
      expect(find.bySemanticsLabel('Desktop lock screen'), findsOneWidget);
      expect(find.byType(ShellWallpaper), findsOneWidget);
    },
  );

  testWidgets('desktop lock uses a click-first sign-in stage', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 600);
    addTearDown(tester.view.reset);
    final service = _FakeAuthenticationService();
    final bridge = _LayoutBridge(_dualOutputLayout);
    addTearDown(() {
      service.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(_host(service: service, bridge: bridge));
    service.emit(_state(locked: true));
    await tester.pump();

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.bySemanticsLabel('Sign in to Denial'), findsOneWidget);
    expect(find.byType(ShellWallpaper), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Sign in to Denial'));
    await tester.pump();
    expect(service.beginCount, 1);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LockScreenLayer)),
    );
    container
        .read(shellSettingsProvider.notifier)
        .setLockScreen(useSystemWallpaper: false);
    await tester.pump();
    expect(find.byType(ShellWallpaper), findsNothing);
  });

  testWidgets('lock screen reuses the centered Home clock presentation', (
    tester,
  ) async {
    final service = _FakeAuthenticationService();
    final bridge = _LayoutBridge(_singleOutputLayout);
    addTearDown(() {
      service.dispose();
      bridge.dispose();
    });

    await tester.pumpWidget(_host(service: service, bridge: bridge));
    service.emit(_state(locked: true));
    await tester.pump();

    final clock = find.byType(HomeClockWidget);
    expect(clock, findsOneWidget);
    final clockText = tester.widgetList<Text>(
      find.descendant(of: clock, matching: find.byType(Text)),
    );
    expect(clockText, hasLength(2));
    expect(
      clockText.every((text) => text.textAlign == TextAlign.center),
      isTrue,
    );
    expect(find.byIcon(Icons.memory_rounded), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LockScreenLayer)),
    );
    container
        .read(shellSettingsProvider.notifier)
        .setLockScreen(showSystemStatus: false);
    await tester.pump();
    expect(find.byIcon(Icons.memory_rounded), findsNothing);
    expect(
      tester.widget<HomeClockWidget>(find.byType(HomeClockWidget)).showStatus,
      isFalse,
    );

    final gradients = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where(
          (box) =>
              box.decoration is BoxDecoration &&
              (box.decoration as BoxDecoration).gradient != null,
        );
    expect(gradients, isEmpty);
  });
}

Widget _host({
  required _FakeAuthenticationService service,
  required _LayoutBridge bridge,
  ShellProfile profile = ShellProfile.desktop,
}) {
  return ProviderScope(
    overrides: <Override>[
      authenticationServiceProvider.overrideWithValue(service),
      settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
      denialBridgeProvider.overrideWithValue(bridge),
      shellProfileProvider.overrideWithValue(profile),
      clockProvider.overrideWith(
        (ref) => Stream<DateTime>.value(DateTime(2026, 7, 17, 12, 34)),
      ),
      powerStatusServiceProvider.overrideWithValue(
        const _FakePowerStatusService(),
      ),
    ],
    child: DenialLocalizationScope(
      child: MediaQuery(
        data: MediaQueryData(size: bridge.layout.logicalSize),
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => const LockScreenLayer(
                unlockProgress: AlwaysStoppedAnimation<double>(0),
                animateDesktopEntrance: false,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MemorySettingsStore implements SettingsStore {
  @override
  Future<ShellSettings?> read() async => null;

  @override
  Future<void> write(ShellSettings settings) async {}
}

class _FakeAuthenticationService implements AuthenticationService {
  _FakeAuthenticationService({this.expectedResponse});

  final String? expectedResponse;
  final StreamController<AuthenticationPacket> _events =
      StreamController<AuthenticationPacket>.broadcast(sync: true);
  int beginCount = 0;
  int lockCount = 0;
  int responseCount = 0;
  bool responseMatched = false;

  @override
  Stream<AuthenticationPacket> get events => _events.stream;

  void emit(AuthenticationPacket packet) => _events.add(packet);

  @override
  void begin() => beginCount += 1;

  @override
  void cancel({required int attemptId}) {}

  @override
  void lock() => lockCount += 1;

  @override
  void respond({
    required int attemptId,
    required int promptSequence,
    required String response,
  }) {
    responseCount += 1;
    responseMatched = response == expectedResponse;
  }

  @override
  void synchronize() {}

  @override
  void dispose() {
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }
}

class _LayoutBridge extends DenialBridge {
  _LayoutBridge(this.layout);

  final DisplayLayout layout;

  @override
  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) async =>
      DenialWindowSnapshot(sequence: 0, windows: fallback);

  @override
  Future<DisplayLayout?> getDisplayLayout() async => layout;
}

class _FakePowerStatusService extends PowerStatusService {
  const _FakePowerStatusService();

  @override
  Future<ShellPowerStatus> read() async => ShellPowerStatus.unknown;
}

AuthenticationPacket _state({required bool locked}) {
  return AuthenticationPacket(
    kind: AuthenticationPacketKind.state,
    locked: locked,
    available: true,
    busy: false,
    rateLimited: false,
    attemptId: 0,
    argument: 0,
    payload: '',
  );
}

AuthenticationPacket _prompt({required int attemptId, required int sequence}) {
  return AuthenticationPacket(
    kind: AuthenticationPacketKind.prompt,
    locked: true,
    available: true,
    busy: true,
    rateLimited: false,
    attemptId: attemptId,
    argument: sequence,
    payload: 'Password:',
    promptStyle: AuthenticationPromptStyle.echoOff,
  );
}

const _singleOutputLayout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(800, 600),
  pixelSize: Size(800, 600),
  engineScale: 1,
  tickerMonitorId: 11,
  systemBarMonitorId: 11,
  systemBarSide: SystemBarSide.left,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 11,
      name: 'main',
      logicalRect: Rect.fromLTWH(0, 0, 800, 600),
      pixelSize: Size(800, 600),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);

const _dualOutputLayout = DisplayLayout(
  epoch: 2,
  globalOrigin: Offset.zero,
  logicalSize: Size(1600, 600),
  pixelSize: Size(1600, 600),
  engineScale: 1,
  tickerMonitorId: 11,
  systemBarMonitorId: 11,
  systemBarSide: SystemBarSide.left,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 11,
      name: 'main',
      logicalRect: Rect.fromLTWH(0, 0, 800, 600),
      pixelSize: Size(800, 600),
      scale: 1,
      refreshRate: 60,
    ),
    DisplayOutput(
      monitorId: 22,
      name: 'secondary',
      logicalRect: Rect.fromLTWH(800, 0, 800, 600),
      pixelSize: Size(800, 600),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);
