import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/config/startup_environment.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_snapshot.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/platform/authentication_protocol.dart';
import 'package:denial_dart_shell/src/services/authentication_service.dart';
import 'package:denial_dart_shell/src/services/lock_state_repository.dart';
import 'package:denial_dart_shell/src/state/authentication.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new native windows do not trigger a shell focus request', () async {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);

    await Future<void>.delayed(Duration.zero);
    bridge.publish(const <DenialWindow>[_mainWindow]);
    bridge.focusedWindowIds.clear();

    bridge.publish(const <DenialWindow>[_mainWindow, _notificationWindow]);

    expect(bridge.focusedWindowIds, isEmpty);
    expect(
      harness.container.read(shellControllerProvider).windows,
      hasLength(2),
    );
  });

  test('native authentication state wins every Dart-side disagreement', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);
    final controller = harness.controller;

    service.emit(_authenticationState(locked: true));
    expect(harness.container.read(shellControllerProvider).locked, isTrue);
    expect(
      harness.container.read(shellControllerProvider).lockLayerVisible,
      isTrue,
    );

    controller.requestUnlock();
    controller.completeUnlockTransition();
    expect(service.beginCount, 1);
    expect(harness.container.read(shellControllerProvider).locked, isTrue);
    expect(
      harness.container.read(shellControllerProvider).lockLayerVisible,
      isTrue,
    );

    service.emit(_authenticationState(locked: false));
    expect(harness.container.read(shellControllerProvider).locked, isFalse);
    expect(
      harness.container.read(shellControllerProvider).lockLayerVisible,
      isTrue,
    );
  });

  test('start-locked environment secures the first visual state', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(
      bridge,
      service,
      environment: StartupEnvironment(const {'DENIA_START_LOCKED': '1'}),
    );

    expect(harness.container.read(shellControllerProvider).locked, isTrue);
    expect(
      harness.container.read(shellControllerProvider).lockLayerVisible,
      isTrue,
    );

    service.emit(_authenticationState(locked: false));
    expect(harness.container.read(shellControllerProvider).locked, isFalse);
  });

  test('minimizing the foreground window releases shell focus', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);
    final controller = harness.controller;
    bridge.publish(const <DenialWindow>[_mainWindow]);
    controller.focusWindow(_mainWindow);
    expect(
      harness.container.read(shellControllerProvider).foregroundObjectId,
      _mainWindow.objectId,
    );

    controller.releaseWindowFocus(_mainWindow);

    expect(
      harness.container.read(shellControllerProvider).foregroundObjectId,
      isNull,
    );
  });

  test('lock-and-blank secures the session before requesting DPMS-off', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);

    harness.controller.lockAndBlankDisplays();

    expect(service.lockCount, 1);
    expect(bridge.dpmsOffCount, 1);
  });

  test('a pending built-in app launch binds its local window', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);
    final requestId = harness.controller.beginAppLaunch(
      appName: 'Settings',
      iconPath: null,
      expectedAppIds: const <String>['dev.denial.settings'],
    );

    bridge.publish(const <DenialWindow>[_settingsWindow]);

    final state = harness.container.read(shellControllerProvider);
    expect(requestId, isNotNull);
    expect(state.foregroundObjectId, _settingsWindow.objectId);
    expect(state.launchingObjectId, _settingsWindow.objectId);
    expect(state.launchingWindow, _settingsWindow);
    expect(bridge.focusedWindowIds, <int>[_settingsWindow.windowId]);
  });

  test('launcher activation animates an existing application window', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);
    bridge.publish(const <DenialWindow>[_mainWindow]);
    bridge.focusedWindowIds.clear();

    final requestId = harness.controller.activateAppFromLauncher(
      window: _mainWindow,
      appName: 'Steam',
      iconPath: null,
    );

    var state = harness.container.read(shellControllerProvider);
    expect(requestId, isNotNull);
    expect(state.launchRequest?.targetObjectId, _mainWindow.objectId);
    expect(state.launchingWindow, _mainWindow);
    expect(state.foregroundWindow, _mainWindow);
    expect(bridge.focusedWindowIds, <int>[_mainWindow.windowId]);

    harness.controller.completeLaunchTransition(
      requestId!,
      _mainWindow.objectId,
    );
    state = harness.container.read(shellControllerProvider);
    expect(state.launchRequest, isNull);
    expect(state.launchingWindow, isNull);
    expect(state.foregroundWindow, _mainWindow);
  });

  test(
    'mobile text input state opens and closes the software keyboard',
    () async {
      final bridge = _TestBridge();
      final service = _TestAuthenticationService();
      final harness = _shellHarness(
        bridge,
        service,
        environment: StartupEnvironment(const {
          'DENIA_SHELL_PROFILE': 'mobile',
        }),
      );

      bridge.publishTextInput(active: true, inputPanelVisible: true);
      expect(
        harness.container.read(shellControllerProvider).edgePanelVisible,
        isTrue,
      );

      bridge.publishTextInput(active: false, inputPanelVisible: false);
      expect(
        harness.container.read(shellControllerProvider).edgePanelVisible,
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 32));
      expect(
        harness.container.read(shellControllerProvider).edgePanelVisible,
        isFalse,
      );
    },
  );

  test('mobile field handoff does not bounce the software keyboard', () async {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(
      bridge,
      service,
      environment: StartupEnvironment(const {'DENIA_SHELL_PROFILE': 'mobile'}),
    );

    bridge.publishTextInput(active: true, inputPanelVisible: true);
    bridge.publishTextInput(active: false, inputPanelVisible: false);
    bridge.publishTextInput(active: true, inputPanelVisible: true);
    await Future<void>.delayed(const Duration(milliseconds: 32));

    expect(
      harness.container.read(shellControllerProvider).edgePanelVisible,
      isTrue,
    );
  });

  test(
    'mobile legacy keyboard fallback is limited to registered terminals',
    () {
      final bridge = _TestBridge();
      final service = _TestAuthenticationService();
      final harness = _shellHarness(
        bridge,
        service,
        environment: StartupEnvironment(const {
          'DENIA_SHELL_PROFILE': 'mobile',
        }),
      );
      bridge.publish(const <DenialWindow>[_mainWindow]);
      harness.controller.focusWindow(_mainWindow);

      bridge.publishTextInput(
        active: true,
        inputPanelVisible: true,
        legacy: true,
      );
      expect(
        harness.container.read(shellControllerProvider).edgePanelVisible,
        isFalse,
      );

      harness.controller.registerLegacyTextInputAppIds(const <String>['steam']);
      bridge.publishTextInput(
        active: true,
        inputPanelVisible: true,
        legacy: true,
      );
      expect(
        harness.container.read(shellControllerProvider).edgePanelVisible,
        isTrue,
      );
    },
  );

  test('mobile lock screen accepts compositor-authorized keyboard taps', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(
      bridge,
      service,
      environment: StartupEnvironment(const {'DENIA_SHELL_PROFILE': 'mobile'}),
    );

    service.emit(_authenticationState(locked: true));
    bridge.publishTextInput(active: true, inputPanelVisible: true);

    expect(
      harness.container.read(shellControllerProvider).edgePanelVisible,
      isTrue,
    );
  });

  test('desktop profile ignores software keyboard visibility', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final harness = _shellHarness(bridge, service);

    bridge.publishTextInput(active: true, inputPanelVisible: true);
    expect(
      harness.container.read(shellControllerProvider).edgePanelVisible,
      isFalse,
    );
  });
}

({ProviderContainer container, ShellController controller}) _shellHarness(
  _TestBridge bridge,
  _TestAuthenticationService service, {
  StartupEnvironment? environment,
}) {
  addTearDown(service.dispose);
  addTearDown(bridge.dispose);
  final container = ProviderContainer.test(
    overrides: [
      denialBridgeProvider.overrideWithValue(bridge),
      lockStateRepositoryProvider.overrideWithValue(_TestLockStateRepository()),
      authenticationServiceProvider.overrideWithValue(service),
      if (environment != null)
        startupEnvironmentProvider.overrideWithValue(environment),
    ],
  );
  return (
    container: container,
    controller: container.read(shellControllerProvider.notifier),
  );
}

class _TestBridge extends DenialBridge {
  ValueChanged<DenialWindowSnapshot>? _onWindowSnapshot;
  final List<int> focusedWindowIds = <int>[];
  int _sequence = 0;
  int dpmsOffCount = 0;
  final StreamController<DenialTextInputState> _textInput =
      StreamController<DenialTextInputState>.broadcast(sync: true);

  @override
  Stream<DenialTextInputState> get textInputStates => _textInput.stream;

  @override
  void start({
    required VoidCallback onWindowsChanged,
    ValueChanged<DenialWindowSnapshot>? onWindowSnapshot,
    required ValueChanged<int> onWindowActivated,
  }) {
    _onWindowSnapshot = onWindowSnapshot;
  }

  @override
  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) async {
    return const DenialWindowSnapshot(sequence: 0, windows: <DenialWindow>[]);
  }

  @override
  void focusWindow(DenialWindow window) {
    focusedWindowIds.add(window.windowId);
  }

  @override
  void requestDpmsOff() {
    dpmsOffCount += 1;
  }

  void publish(List<DenialWindow> windows) {
    _onWindowSnapshot?.call(
      DenialWindowSnapshot(sequence: ++_sequence, windows: windows),
    );
  }

  void publishTextInput({
    required bool active,
    required bool inputPanelVisible,
    bool legacy = false,
  }) {
    _textInput.add(
      DenialTextInputState(
        active: active,
        inputPanelVisible: inputPanelVisible,
        legacy: legacy,
        contentHint: 0,
        contentPurpose: 0,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_textInput.close());
    super.dispose();
  }
}

class _TestLockStateRepository extends LockStateRepository {
  _TestLockStateRepository()
    : super(
        requestPath: '/tmp/denial-shell-controller-test-request',
        secureStatePath: '/tmp/denial-shell-controller-test-secure',
      );

  @override
  void start({required LockRequestChanged onChanged}) {}

  @override
  void publishSecure(bool secure) {}

  @override
  void acknowledgeUnlocked() {}

  @override
  void dispose() {}
}

class _TestAuthenticationService implements AuthenticationService {
  final StreamController<AuthenticationPacket> _events =
      StreamController<AuthenticationPacket>.broadcast(sync: true);
  int beginCount = 0;
  int lockCount = 0;

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
  }) {}

  @override
  void synchronize() {}

  @override
  void dispose() {
    _events.close();
  }
}

AuthenticationPacket _authenticationState({required bool locked}) {
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

const _mainWindow = DenialWindow(
  objectId: 1,
  objectKind: 'root_surface',
  surfaceId: 1,
  windowId: 101,
  textureId: 1001,
  title: 'Steam',
  appId: 'steam',
  width: 1120,
  height: 700,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 1120,
  surfaceHeight: 700,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 1120,
  textureSourceHeight: 700,
  geometryX: 720,
  geometryY: 370,
  geometryWidth: 1120,
  geometryHeight: 700,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);

const _notificationWindow = DenialWindow(
  objectId: 2,
  objectKind: 'root_surface',
  surfaceId: 2,
  windowId: 102,
  textureId: 1002,
  title: 'notificationtoasts_10000_desktop',
  appId: 'steam',
  width: 283,
  height: 70,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 283,
  surfaceHeight: 70,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 283,
  textureSourceHeight: 70,
  geometryX: 2277,
  geometryY: 1510,
  geometryWidth: 283,
  geometryHeight: 70,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);

const _settingsWindow = DenialWindow(
  objectId: 91,
  objectKind: 'local_flutter',
  surfaceId: 91,
  windowId: 91,
  textureId: 0,
  title: 'Settings',
  appId: 'dev.denial.settings',
  width: 900,
  height: 620,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 900,
  surfaceHeight: 620,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 0,
  textureSourceHeight: 0,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 900,
  geometryHeight: 620,
  monitorId: 1,
  transform: 0,
  scale120: 120,
  serverSideDecorated: false,
  contentKind: DenialWindowContentKind.localFlutter,
);
