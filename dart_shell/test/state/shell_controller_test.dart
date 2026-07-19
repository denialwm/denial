import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
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
    final authentication = AuthenticationController(service);
    final controller = ShellController(
      bridge,
      _TestLockStateRepository(),
      authentication,
    );
    addTearDown(() {
      controller.dispose();
      authentication.dispose();
      service.dispose();
      bridge.dispose();
    });

    await Future<void>.delayed(Duration.zero);
    bridge.publish(const <DenialWindow>[_mainWindow]);
    bridge.focusedWindowIds.clear();

    bridge.publish(const <DenialWindow>[_mainWindow, _notificationWindow]);

    expect(bridge.focusedWindowIds, isEmpty);
    expect(controller.state.windows, hasLength(2));
  });

  test('native authentication state wins every Dart-side disagreement', () {
    final bridge = _TestBridge();
    final service = _TestAuthenticationService();
    final authentication = AuthenticationController(service);
    final controller = ShellController(
      bridge,
      _TestLockStateRepository(),
      authentication,
    );
    addTearDown(() {
      controller.dispose();
      authentication.dispose();
      service.dispose();
      bridge.dispose();
    });

    service.emit(_authenticationState(locked: true));
    controller.handleAuthenticationState(authentication.state);
    expect(controller.state.locked, isTrue);
    expect(controller.state.lockLayerVisible, isTrue);

    controller.requestUnlock();
    controller.completeUnlockTransition();
    expect(service.beginCount, 1);
    expect(controller.state.locked, isTrue);
    expect(controller.state.lockLayerVisible, isTrue);

    service.emit(_authenticationState(locked: false));
    controller.handleAuthenticationState(authentication.state);
    expect(controller.state.locked, isFalse);
    expect(controller.state.lockLayerVisible, isTrue);
  });
}

class _TestBridge extends DenialBridge {
  ValueChanged<DenialWindowSnapshot>? _onWindowSnapshot;
  final List<int> focusedWindowIds = <int>[];
  int _sequence = 0;

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

  void publish(List<DenialWindow> windows) {
    _onWindowSnapshot?.call(DenialWindowSnapshot(
      sequence: ++_sequence,
      windows: windows,
    ));
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

  @override
  Stream<AuthenticationPacket> get events => _events.stream;

  void emit(AuthenticationPacket packet) => _events.add(packet);

  @override
  void begin() => beginCount += 1;

  @override
  void cancel({required int attemptId}) {}

  @override
  void lock() {}

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
