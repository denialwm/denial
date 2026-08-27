import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/input/input_layout.dart';
import 'package:denial_dart_shell/src/models/denial_drag_icon.dart';
import 'package:denial_dart_shell/src/models/desktop_notification.dart'
    as notification_model;
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart'
    show SystemBarSide;
import 'package:denial_dart_shell/src/models/input_device_capabilities.dart';
import 'package:denial_dart_shell/src/models/keyboard_configuration.dart';
import 'package:denial_dart_shell/src/models/system_tray_item.dart'
    as tray_model;
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/platform/denial_wire.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native control messages use bounded binary payloads', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final systemMessages = <ByteData>[];
    final brightnessMessages = <ByteData>[];
    final idlePolicyMessages = <ByteData>[];
    final displayPowerMessages = <ByteData>[];
    messenger.setMockMessageHandler('denial/system_command', (message) async {
      systemMessages.add(message!);
      return null;
    });
    messenger.setMockMessageHandler('denial/brightness', (message) async {
      brightnessMessages.add(message!);
      return null;
    });
    messenger.setMockMessageHandler('denial/idle_policy', (message) async {
      idlePolicyMessages.add(message!);
      return null;
    });
    messenger.setMockMessageHandler('denial/display_power', (message) async {
      displayPowerMessages.add(message!);
      return null;
    });

    final bridge = DenialBridge();
    try {
      expect(
        bridge.launchApplication(const <String>[
          'foot',
          '--title',
          'Denial shell',
        ], launchRequestId: 42),
        isTrue,
      );
      expect(bridge.takeScreenshot(), isTrue);
      expect(bridge.screenshotPrepared(77), isTrue);
      expect(
        bridge.finishScreenshotRegion(
          77,
          const Rect.fromLTWH(12.5, 24, 640, 480),
        ),
        isTrue,
      );
      expect(
        bridge.finishScreenshotRegion(77, const Rect.fromLTWH(-1, 0, 10, 10)),
        isFalse,
      );
      expect(bridge.cancelScreenshot(77), isTrue);
      expect(bridge.requestLogout(), isTrue);
      expect(
        bridge.launchDesktopApplication(
          'org.example.Terminal.desktop',
          const <String>['foot'],
          launchRequestId: 43,
        ),
        isTrue,
      );
      expect(
        bridge.launchApplication(const <String>['bad\u0000argument']),
        isFalse,
      );
      expect(bridge.requestBrightness(monitorId: 7, connector: 'DP-4'), isTrue);
      expect(
        bridge.setBrightness(monitorId: 7, connector: 'DP-4', level: 0.375),
        isTrue,
      );
      expect(
        bridge.setBrightness(monitorId: -1, connector: 'DP-4', level: 0.5),
        isFalse,
      );
      bridge.setIdleDpmsTimeout(const Duration(minutes: 17));
      bridge.setIdleDpmsTimeout(null);
      bridge.requestDpmsOff();

      expect(systemMessages, hasLength(7));
      final launch = systemMessages[0];
      expect(launch.getUint8(0), 0);
      expect(launch.getUint64(1, Endian.little), 42);
      expect(launch.getUint32(9, Endian.little), 3);
      expect(_decodeSystemArguments(launch), const <String>[
        'foot',
        '--title',
        'Denial shell',
      ]);

      expect(systemMessages[1].getUint8(0), 2);
      expect(systemMessages[1].lengthInBytes, 13);
      expect(systemMessages[2].getUint8(0), 4);
      expect(systemMessages[2].getUint64(1, Endian.little), 77);
      expect(systemMessages[2].lengthInBytes, 13);
      expect(systemMessages[3].getUint8(0), 2);
      expect(systemMessages[3].getUint64(1, Endian.little), 77);
      expect(_decodeSystemArguments(systemMessages[3]), const <String>[
        '12.500000',
        '24.000000',
        '640.000000',
        '480.000000',
      ]);
      expect(systemMessages[4].getUint8(0), 5);
      expect(systemMessages[4].getUint64(1, Endian.little), 77);
      expect(systemMessages[4].lengthInBytes, 13);
      expect(systemMessages[5].getUint8(0), 3);
      expect(systemMessages[5].lengthInBytes, 13);
      expect(systemMessages[6].getUint8(0), 1);
      expect(systemMessages[6].getUint64(1, Endian.little), 43);
      expect(_decodeSystemArguments(systemMessages[6]), const <String>[
        'org.example.Terminal.desktop',
        'foot',
      ]);

      expect(brightnessMessages, hasLength(2));
      final brightnessRead = brightnessMessages.first;
      expect(brightnessRead.lengthInBytes, 16);
      expect(brightnessRead.getUint8(0), 0);
      expect(brightnessRead.getInt64(1, Endian.little), 7);
      expect(brightnessRead.getUint8(9), 0);
      expect(brightnessRead.getUint16(10, Endian.little), 4);
      expect(_brightnessConnector(brightnessRead), 'DP-4');

      final brightnessSet = brightnessMessages.last;
      expect(brightnessSet.lengthInBytes, 16);
      expect(brightnessSet.getUint8(0), 1);
      expect(brightnessSet.getInt64(1, Endian.little), 7);
      expect(brightnessSet.getUint8(9), 38);
      expect(brightnessSet.getUint16(10, Endian.little), 4);
      expect(_brightnessConnector(brightnessSet), 'DP-4');
      expect(idlePolicyMessages, hasLength(2));
      expect(
        idlePolicyMessages.first.getUint64(0, Endian.little),
        const Duration(minutes: 17).inMilliseconds,
      );
      expect(idlePolicyMessages.last.getUint64(0, Endian.little), 0);
      expect(displayPowerMessages, hasLength(1));
      expect(displayPowerMessages.single.lengthInBytes, 1);
      expect(displayPowerMessages.single.getUint8(0), 1);
    } finally {
      bridge.dispose();
      messenger.setMockMessageHandler('denial/system_command', null);
      messenger.setMockMessageHandler('denial/brightness', null);
      messenger.setMockMessageHandler('denial/idle_policy', null);
      messenger.setMockMessageHandler('denial/display_power', null);
    }
  });

  test('close completion uses one bounded little-endian window ID', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final completions = <ByteData>[];
    messenger.setMockMessageHandler('denial/window_close_complete', (
      message,
    ) async {
      completions.add(message!);
      return null;
    });

    final bridge = DenialBridge();
    try {
      expect(bridge.completeWindowClose(0), isFalse);
      expect(bridge.completeWindowClose(-1), isFalse);
      expect(bridge.completeWindowClose(0x0102030405060708), isTrue);

      expect(completions, hasLength(1));
      expect(completions.single.lengthInBytes, 8);
      expect(
        completions.single.getUint64(0, Endian.little),
        0x0102030405060708,
      );
    } finally {
      bridge.dispose();
      messenger.setMockMessageHandler('denial/window_close_complete', null);
    }
  });

  test('window and display replies match distinct request IDs', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requests = <wire.Envelope>[];
    messenger.setMockMessageHandler(wire.denialWireToNativeChannel, (
      message,
    ) async {
      requests.add(wire.Envelope(_bytes(message!)));
      return null;
    });

    final bridge = _startedBridge();
    try {
      final windowsFuture = bridge.listWindows(const <DenialWindow>[]);
      final displayFuture = bridge.getDisplayLayout();

      expect(requests, hasLength(2));
      final windowRequest = requests[0].payload as wire.WindowRequest;
      final displayRequest = requests[1].payload as wire.WindowRequest;
      expect(windowRequest.kind, wire.WindowRequestKind.ListWindows);
      expect(displayRequest.kind, wire.WindowRequestKind.GetDisplayLayout);
      expect(requests[0].requestId, isNonZero);
      expect(requests[1].requestId, isNot(requests[0].requestId));

      var windowsCompleted = false;
      unawaited(windowsFuture.then((_) => windowsCompleted = true));
      await _sendToFlutter(
        messenger,
        _windowResponse(requestId: requests[0].requestId + 100),
      );
      await Future<void>.delayed(Duration.zero);
      expect(windowsCompleted, isFalse, reason: 'wrong request ID completed');

      await _sendToFlutter(
        messenger,
        _displayResponse(requestId: requests[1].requestId),
      );
      final display = await displayFuture;
      expect(display, isNotNull);
      expect(display!.epoch, 0x100000001);
      expect(display.logicalSize, const Size(1920, 1080));
      expect(display.systemBarSide, SystemBarSide.top);
      expect(display.systemBarThickness, 32.0);
      expect(display.effectiveSystemBarMonitorIds, <int>[4]);

      await _sendToFlutter(
        messenger,
        _windowResponse(requestId: requests[0].requestId),
      );
      final snapshot = await windowsFuture;
      expect(snapshot.sequence, 41);
      expect(snapshot.windows, hasLength(1));
      expect(snapshot.windows.single.objectId, 0x100000000);
      expect(snapshot.windows.single.title, 'Golden café 🐒');
      expect(snapshot.windows.single.pinned, isTrue);
    } finally {
      bridge.dispose();
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
    }
  });

  test('unsolicited display layout replies publish live topology', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    try {
      final update = bridge.displayLayouts.first;
      await _sendToFlutter(messenger, _displayResponse(requestId: 0));

      final display = await update;
      expect(display.epoch, 0x100000001);
      expect(display.logicalSize, const Size(1920, 1080));
      expect(display.outputs.single.name, 'eDP-1');
    } finally {
      bridge.dispose();
    }
  });

  test(
    'settings and keyboard replies stay revisioned on the typed bridge',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final requests = <wire.Envelope>[];
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, (
        message,
      ) async {
        requests.add(wire.Envelope(_bytes(message!)));
        return null;
      });
      final bridge = _startedBridge();
      final keyboardEvents = <DenialKeyboardConfiguration>[];
      final subscription = bridge.keyboardConfigurations.listen(
        keyboardEvents.add,
      );
      final inputDeviceEvents = <DenialInputDeviceCapabilities>[];
      final inputDeviceSubscription = bridge.inputDeviceCapabilities.listen(
        inputDeviceEvents.add,
      );
      try {
        final documentFuture = bridge.readSettingsDocument();
        final keyboardFuture = bridge.readKeyboardConfiguration();
        final inputDevicesFuture = bridge.readInputDeviceCapabilities();
        expect(requests, hasLength(3));
        expect(
          (requests[0].payload as wire.SettingsRequest).kind,
          wire.SettingsRequestKind.ReadDocument,
        );
        expect(
          (requests[1].payload as wire.SettingsRequest).kind,
          wire.SettingsRequestKind.ReadKeyboard,
        );
        expect(
          (requests[2].payload as wire.SettingsRequest).kind,
          wire.SettingsRequestKind.ReadInputDevices,
        );

        await _sendToFlutter(
          messenger,
          _settingsDocumentResponse(
            requestId: requests[0].requestId,
            revision: 7,
            document: '{"version":9,"revision":7}',
          ),
        );
        final document = await documentFuture;
        expect(document.revision, 7);
        expect(document.json, contains('"revision":7'));

        await _sendToFlutter(
          messenger,
          _keyboardSettingsResponse(
            requestId: requests[1].requestId,
            revision: 7,
            activeLayout: 1,
          ),
        );
        final keyboard = await keyboardFuture;
        expect(keyboard.active.label, 'German');
        expect(keyboard.repeatDelayMs, 450);
        expect(keyboard.repeatRateHz, 30);

        await _sendToFlutter(
          messenger,
          _inputDeviceCapabilitiesResponse(
            requestId: requests[2].requestId,
            hasTouchpad: true,
          ),
        );
        final inputDevices = await inputDevicesFuture;
        expect(inputDevices.hasTouchpad, isTrue);
        expect(inputDevices.tapToClickEnabled, isTrue);
        expect(inputDevices.naturalScrollEnabled, isFalse);
        expect(inputDevices.scrollSpeedFactor, 1);

        final update = bridge.configureKeyboard(
          keyboard.copyWith(repeatRateHz: 40),
        );
        final configureEnvelope = requests.last;
        final configure = configureEnvelope.payload as wire.SettingsRequest;
        expect(configure.kind, wire.SettingsRequestKind.ConfigureKeyboard);
        expect(configure.expectedRevision, 7);
        expect(configure.keyboard!.repeatRateHz, 40);
        await _sendToFlutter(
          messenger,
          _keyboardSettingsResponse(
            requestId: configureEnvelope.requestId,
            revision: 8,
            activeLayout: 0,
            repeatRateHz: 40,
          ),
        );
        expect((await update).revision, 8);

        final touchpadUpdate = bridge.configureTouchpad(
          inputDevices.copyWith(
            tapToClickEnabled: false,
            naturalScrollEnabled: true,
            scrollSpeedFactor: 2.5,
          ),
        );
        final touchpadEnvelope = requests.last;
        final touchpadRequest =
            touchpadEnvelope.payload as wire.SettingsRequest;
        expect(
          touchpadRequest.kind,
          wire.SettingsRequestKind.ConfigureTouchpad,
        );
        expect(touchpadRequest.expectedRevision, 7);
        expect(touchpadRequest.touchpad!.tapToClickEnabled, isFalse);
        expect(touchpadRequest.touchpad!.naturalScrollEnabled, isTrue);
        expect(touchpadRequest.touchpad!.scrollSpeedFactor, 2.5);
        await _sendToFlutter(
          messenger,
          _inputDeviceCapabilitiesResponse(
            requestId: touchpadEnvelope.requestId,
            revision: 9,
            hasTouchpad: true,
            tapToClickEnabled: false,
            naturalScrollEnabled: true,
            scrollSpeedFactor: 2.5,
          ),
        );
        final updatedTouchpad = await touchpadUpdate;
        expect(updatedTouchpad.revision, 9);
        expect(updatedTouchpad.tapToClickEnabled, isFalse);
        expect(updatedTouchpad.naturalScrollEnabled, isTrue);
        expect(updatedTouchpad.scrollSpeedFactor, 2.5);

        await _sendToFlutter(
          messenger,
          _keyboardSettingsResponse(
            requestId: 0,
            revision: 8,
            activeLayout: 1,
            repeatRateHz: 40,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(keyboardEvents.last.active.label, 'German');
        expect(keyboardEvents.last.revision, 8);

        await _sendToFlutter(
          messenger,
          _inputDeviceCapabilitiesResponse(
            requestId: 0,
            revision: 9,
            hasTouchpad: false,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(inputDeviceEvents.last.hasTouchpad, isFalse);
      } finally {
        await subscription.cancel();
        await inputDeviceSubscription.cancel();
        bridge.dispose();
        messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
      }
    },
  );

  test('placement begin, update, and end keep wire order', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final events = <DenialWindowPlacementEvent>[];
    final subscription = bridge.windowEvents
        .where((event) => event is DenialWindowPlacementEvent)
        .cast<DenialWindowPlacementEvent>()
        .listen(events.add);
    try {
      for (var index = 0; index < 3; index += 1) {
        await messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          _placementPacket(
            sequence: index + 1,
            phase: DenialWindowPlacementPhase.values[index],
          ),
          null,
        );
      }

      expect(
        events.map((event) => event.phase),
        orderedEquals(const <DenialWindowPlacementPhase>[
          DenialWindowPlacementPhase.begin,
          DenialWindowPlacementPhase.update,
          DenialWindowPlacementPhase.end,
        ]),
      );
      expect(events.map((event) => event.monitorId), everyElement(4));
      expect(events.map((event) => event.workspaceId), everyElement(7));
      expect(events.map((event) => event.contentRect.left), <double>[1, 2, 3]);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test(
    'input layout reports whether it was encoded and handed to native',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <ByteData>[];
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, (
        message,
      ) async {
        sent.add(message!);
        return null;
      });
      final bridge = _startedBridge();
      try {
        expect(
          bridge.publishInputLayout(
            const InputLayoutSnapshot(
              epoch: 1,
              shellRegions: <Rect>[Rect.fromLTWH(0, 0, 0, 1)],
              windows: <InputWindowRegion>[],
            ),
          ),
          isFalse,
        );
        expect(
          bridge.publishInputLayout(
            const InputLayoutSnapshot(
              epoch: 1,
              shellRegions: <Rect>[Rect.fromLTWH(0, 0, 0.25, 0.5)],
              windows: <InputWindowRegion>[],
            ),
          ),
          isTrue,
        );
        expect(sent, hasLength(1));
      } finally {
        bridge.dispose();
        messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
      }
    },
  );

  test('placement and structured events share one ordered stream', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final order = <String>[];
    final bridge = DenialBridge()
      ..start(
        onWindowsChanged: () {},
        onWindowActivated: (windowId) => order.add('active:$windowId'),
      );
    final subscription = bridge.windowEvents
        .where((event) => event is DenialWindowPlacementEvent)
        .listen((_) => order.add('placement'));
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.WindowEvent,
          wire.WindowEventObjectBuilder(
            kind: wire.WindowEventKind.Activated,
            windowId: 11,
          ),
        ),
      );
      await messenger.handlePlatformMessage(
        wire.denialWireToFlutterChannel,
        _placementPacket(sequence: 42, phase: DenialWindowPlacementPhase.begin),
        null,
      );
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.WindowEvent,
          wire.WindowEventObjectBuilder(
            kind: wire.WindowEventKind.Activated,
            windowId: 12,
          ),
        ),
      );

      expect(order, <String>['active:11', 'placement', 'active:12']);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test(
    'unsolicited snapshot is applied synchronously before next texture mark',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final order = <String>[];
      final bridge = DenialBridge();
      bridge.start(
        onWindowsChanged: () {},
        onWindowSnapshot: (snapshot) {
          expect(snapshot.sequence, 41);
          expect(snapshot.windows.single.textureId, 7);
          order.add('metadata');
        },
        onWindowActivated: (_) {},
      );
      try {
        final handling = messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          ByteData.sublistView(_windowSnapshot()),
          null,
        );
        order.add('texture_mark');
        expect(order, <String>['metadata', 'texture_mark']);
        await handling;
      } finally {
        bridge.dispose();
      }
    },
  );

  test('native activation event is forwarded to the shell', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    int? activatedWindowId;
    final bridge = DenialBridge()
      ..start(
        onWindowsChanged: () {},
        onWindowActivated: (windowId) => activatedWindowId = windowId,
      );
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.WindowEvent,
          wire.WindowEventObjectBuilder(
            kind: wire.WindowEventKind.Activated,
            windowId: 0x18000002,
          ),
        ),
      );

      expect(activatedWindowId, 0x18000002);
    } finally {
      bridge.dispose();
    }
  });

  test(
    'screenshot lifecycle preserves request and texture identities',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final bridge = _startedBridge();
      final events = <DenialShellActionEvent>[];
      final subscription = bridge.shellActions.listen(events.add);
      try {
        for (final (action, textureId) in <(wire.ShellActionKind, int)>[
          (wire.ShellActionKind.ScreenshotRegion, 0),
          (wire.ShellActionKind.ScreenshotTextureReady, 9001),
          (wire.ShellActionKind.ScreenshotDone, 0),
        ]) {
          await _sendToFlutter(
            messenger,
            _envelope(
              wire.PayloadTypeId.ShellAction,
              wire.ShellActionObjectBuilder(
                action: action,
                textureId: textureId,
              ),
              requestId: 41,
            ),
          );
        }

        expect(events.map((event) => event.action), <DenialShellAction>[
          DenialShellAction.screenshotPrepare,
          DenialShellAction.screenshotTextureReady,
          DenialShellAction.screenshotDone,
        ]);
        expect(events.map((event) => event.requestId), everyElement(41));
        expect(events.map((event) => event.textureId), <int?>[
          null,
          9001,
          null,
        ]);
      } finally {
        await subscription.cancel();
        bridge.dispose();
      }
    },
  );

  test('window switcher directions and release reach the shell', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final events = <DenialShellActionEvent>[];
    final subscription = bridge.shellActions.listen(events.add);
    try {
      for (final action in <wire.ShellActionKind>[
        wire.ShellActionKind.WindowSwitcherNext,
        wire.ShellActionKind.WindowSwitcherPrevious,
        wire.ShellActionKind.WindowSwitcherEnd,
      ]) {
        await _sendToFlutter(
          messenger,
          _envelope(
            wire.PayloadTypeId.ShellAction,
            wire.ShellActionObjectBuilder(action: action),
          ),
        );
      }

      expect(events.map((event) => event.action), <DenialShellAction>[
        DenialShellAction.windowSwitcherNext,
        DenialShellAction.windowSwitcherPrevious,
        DenialShellAction.windowSwitcherEnd,
      ]);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test('client pointer press notifications reach the shell', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final events = <DenialShellActionEvent>[];
    final subscription = bridge.shellActions.listen(events.add);
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.ShellAction,
          wire.ShellActionObjectBuilder(
            action: wire.ShellActionKind.ClientPointerPressed,
          ),
        ),
      );

      expect(events, hasLength(1));
      expect(events.single.action, DenialShellAction.clientPointerPressed);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test('wallpaper action notifications reach the shell', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final events = <DenialShellActionEvent>[];
    final subscription = bridge.shellActions.listen(events.add);
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.ShellAction,
          wire.ShellActionObjectBuilder(action: wire.ShellActionKind.Wallpaper),
        ),
      );

      expect(events, hasLength(1));
      expect(events.single.action, DenialShellAction.wallpaper);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test('open Settings action notifications reach the shell', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final events = <DenialShellActionEvent>[];
    final subscription = bridge.shellActions.listen(events.add);
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.ShellAction,
          wire.ShellActionObjectBuilder(
            action: wire.ShellActionKind.OpenSettings,
          ),
        ),
      );

      expect(events, hasLength(1));
      expect(events.single.action, DenialShellAction.openSettings);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test('wallpaper requests use the compositor control socket', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-wallpaper-control-',
    );
    final socketPath = '${directory.path}/control.sock';
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    addTearDown(() async {
      await server.close();
      await directory.delete(recursive: true);
    });
    final request = server.first.then((socket) async {
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first;
      final decoded = jsonDecode(line) as Map<String, Object?>;
      socket.write(
        '${jsonEncode(<String, Object>{'version': 1, 'id': decoded['id']! as int, 'ok': true, 'result': <String, Object>{}})}\n',
      );
      await socket.flush();
      await socket.close();
      return decoded;
    });
    final bridge = DenialBridge(
      useControlSocket: true,
      controlSocketPath: socketPath,
    );
    try {
      await bridge.openWallpaperSelector();
      final decoded = await request;
      expect(decoded['version'], 1);
      expect(decoded['method'], 'shell.wallpaper.open');
      expect(decoded.containsKey('params'), isFalse);
    } finally {
      bridge.dispose();
    }
  });

  test(
    'control-socket settings subscription is seeded and streams revisions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'denial-settings-control-',
      );
      final socketPath = '${directory.path}/control.sock';
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final subscribed = Completer<({Socket socket, int requestId})>();
      final connections = server.listen((socket) async {
        final line = await utf8.decoder
            .bind(socket)
            .transform(const LineSplitter())
            .first;
        final decoded = jsonDecode(line) as Map<String, Object?>;
        expect(decoded['method'], 'settings.document.subscribe');
        socket.write(
          '${jsonEncode(<String, Object>{
            'version': 1,
            'id': decoded['id']! as int,
            'ok': true,
            'result': <String, Object>{'revision': 7, 'document': '{"version":10,"revision":7}'},
          })}\n',
        );
        await socket.flush();
        subscribed.complete((socket: socket, requestId: decoded['id']! as int));
      });
      final bridge = DenialBridge(
        useControlSocket: true,
        controlSocketPath: socketPath,
      );
      final initial = Completer<DenialSettingsDocument>();
      final updated = Completer<DenialSettingsDocument>();
      final subscription = bridge.settingsDocuments.listen((document) {
        if (document.revision == 7 && !initial.isCompleted) {
          initial.complete(document);
        }
        if (document.revision == 8 && !updated.isCompleted) {
          updated.complete(document);
        }
      });
      try {
        expect(
          (await initial.future.timeout(const Duration(seconds: 1))).revision,
          7,
        );
        final connection = await subscribed.future;
        connection.socket.write(
          '${jsonEncode(<String, Object>{
            'version': 1,
            'id': connection.requestId,
            'ok': true,
            'result': <String, Object>{'revision': 8, 'document': '{"version":10,"revision":8}'},
          })}\n',
        );
        await connection.socket.flush();
        expect(
          (await updated.future.timeout(const Duration(seconds: 1))).json,
          contains('"revision":8'),
        );
      } finally {
        await subscription.cancel();
        bridge.dispose();
        await connections.cancel();
        await server.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'native cursor positions are forwarded without pointer synthesis',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final bridge = _startedBridge();
      final positions = <Offset>[];
      final subscription = bridge.cursorPositions.listen(positions.add);
      try {
        await _sendToFlutter(
          messenger,
          _envelope(
            wire.PayloadTypeId.CursorPosition,
            wire.CursorPositionObjectBuilder(x: 123.5, y: 77.25),
          ),
        );

        expect(positions, const <Offset>[Offset(123.5, 77.25)]);
      } finally {
        await subscription.cancel();
        bridge.dispose();
      }
    },
  );

  test('native text input state drives the typed bridge stream', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final states = <DenialTextInputState>[];
    final subscription = bridge.textInputStates.listen(states.add);
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.TextInputState,
          wire.TextInputStateObjectBuilder(
            active: true,
            inputPanelVisible: true,
            legacy: true,
            contentHint: 3,
            contentPurpose: 6,
          ),
        ),
      );
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.TextInputState,
          wire.TextInputStateObjectBuilder(
            active: false,
            inputPanelVisible: false,
          ),
        ),
      );
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.TextInputState,
          wire.TextInputStateObjectBuilder(
            active: false,
            inputPanelVisible: true,
          ),
        ),
      );

      expect(states, hasLength(2));
      expect(states.first.active, isTrue);
      expect(states.first.inputPanelVisible, isTrue);
      expect(states.first.legacy, isTrue);
      expect(states.first.contentHint, 3);
      expect(states.first.contentPurpose, 6);
      expect(states.last.active, isFalse);
      expect(states.last.inputPanelVisible, isFalse);
      expect(states.last.legacy, isFalse);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test(
    'native drag-icon textures are forwarded and cleared in wire order',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final bridge = _startedBridge();
      final icons = <DenialDragIcon?>[];
      final subscription = bridge.dragIcons.listen(icons.add);
      try {
        await messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          _dragIconPacket(sequence: 1),
          null,
        );
        await messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          _dragIconPacket(sequence: 2, active: false),
          null,
        );

        expect(icons, hasLength(2));
        expect(icons.first, isNotNull);
        expect(icons.first!.surfaceId, 0x200000004);
        expect(icons.first!.layer.textureId, 7);
        expect(icons.first!.offset, const Offset(-12.5, 8.25));
        expect(icons.last, isNull);
      } finally {
        await subscription.cancel();
        bridge.dispose();
      }
    },
  );

  test('desktop notification events are decoded and forwarded', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final events = <notification_model.DesktopNotificationEvent>[];
    final subscription = bridge.notificationEvents.listen(events.add);
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.DesktopNotificationEvent,
          wire.DesktopNotificationEventObjectBuilder(
            kind: wire.DesktopNotificationEventKind.Added,
            notificationId: 7,
            notification: wire.DesktopNotificationObjectBuilder(
              id: 7,
              sender: ':1.42',
              appName: 'Notification test client',
              appIcon: 'dialog-information',
              summary: 'Build complete',
              body: 'All notification fields crossed the native bridge.',
              actions: <wire.DesktopNotificationActionObjectBuilder>[
                wire.DesktopNotificationActionObjectBuilder(
                  key: 'open',
                  label: 'Open',
                ),
              ],
              urgency: wire.DesktopNotificationUrgency.Critical,
              category: 'transfer.complete',
              desktopEntry: 'dev.denial.NotificationTestClient',
              imagePath: '/tmp/notification.png',
              imageData: wire.DesktopNotificationImageDataObjectBuilder(
                width: 2,
                height: 2,
                rowStride: 8,
                hasAlpha: true,
                bitsPerSample: 8,
                channels: 4,
                data: List<int>.generate(16, (index) => index),
              ),
              resident: true,
              transient: false,
              suppressSound: true,
              actionIcons: false,
              soundName: 'message-new-instant',
              soundFile: '/tmp/notification.oga',
              x: 320,
              y: 180,
              hasPosition: true,
              progress: 84,
              hasProgress: true,
              expireTimeoutMs: 9000,
            ),
          ),
        ),
      );

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.kind, notification_model.DesktopNotificationEventKind.added);
      expect(event.notificationId, 7);
      expect(event.notification!.summary, 'Build complete');
      expect(
        event.notification!.urgency,
        notification_model.DesktopNotificationUrgency.critical,
      );
      expect(event.notification!.actions.single.key, 'open');
      expect(event.notification!.imageData!.data, hasLength(16));
      expect(event.notification!.progress, 84);
      expect(event.notification!.hasPosition, isTrue);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test('notification commands are encoded for native', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final commands = <wire.DesktopNotificationCommand>[];
    messenger.setMockMessageHandler(wire.denialWireToNativeChannel, (
      message,
    ) async {
      final envelope = wire.Envelope(_bytes(message!));
      expect(
        envelope.payloadType,
        wire.PayloadTypeId.DesktopNotificationCommand,
      );
      commands.add(envelope.payload as wire.DesktopNotificationCommand);
      return null;
    });
    final bridge = _startedBridge();
    try {
      expect(bridge.dismissNotification(17), isTrue);
      expect(bridge.invokeNotificationAction(17, 'reply'), isTrue);
      expect(bridge.invokeDefaultNotificationAction(17), isTrue);
      expect(bridge.dismissNotification(0), isFalse);
      expect(bridge.dismissNotification(0x100000000), isFalse);
      expect(bridge.invokeNotificationAction(17, ''), isFalse);
      expect(
        bridge.invokeNotificationAction(
          17,
          List<String>.filled(4097, 'a').join(),
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);

      expect(commands, hasLength(3));
      expect(commands[0].kind, wire.DesktopNotificationCommandKind.Dismiss);
      expect(commands[0].notificationId, 17);
      expect(commands[0].actionKey, isNull);
      expect(
        commands[1].kind,
        wire.DesktopNotificationCommandKind.InvokeAction,
      );
      expect(commands[1].actionKey, 'reply');
      expect(
        commands[2].kind,
        wire.DesktopNotificationCommandKind.InvokeDefault,
      );
      expect(commands[2].actionKey, isNull);
    } finally {
      bridge.dispose();
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
    }
  });

  test('XEmbed tray events are cached and forwarded', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    try {
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.XEmbedTrayEvent,
          wire.XembedTrayEventObjectBuilder(
            kind: wire.XembedTrayEventKind.Added,
            windowId: 42,
            icon: wire.XembedTrayIconObjectBuilder(
              windowId: 42,
              title: 'Steam',
              width: 1,
              height: 1,
              rgba: const <int>[10, 20, 30, 255],
            ),
          ),
        ),
      );

      expect(bridge.xembedTrayItems.keys, <int>[42]);
      expect(bridge.xembedTrayItems[42]!.title, 'Steam');
      expect(
        bridge.xembedTrayItems[42]!.source,
        tray_model.SystemTrayItemSource.xEmbed,
      );

      final events = <tray_model.XEmbedTrayEvent>[];
      final subscription = bridge.xembedTrayEvents.listen(events.add);
      await _sendToFlutter(
        messenger,
        _envelope(
          wire.PayloadTypeId.XEmbedTrayEvent,
          wire.XembedTrayEventObjectBuilder(
            kind: wire.XembedTrayEventKind.Removed,
            windowId: 42,
          ),
        ),
      );
      expect(events.single.kind, tray_model.XEmbedTrayEventKind.removed);
      expect(bridge.xembedTrayItems, isEmpty);
      await subscription.cancel();
    } finally {
      bridge.dispose();
    }
  });

  test('XEmbed tray actions are encoded for native', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final commands = <wire.XembedTrayCommand>[];
    messenger.setMockMessageHandler(wire.denialWireToNativeChannel, (
      message,
    ) async {
      final envelope = wire.Envelope(_bytes(message!));
      expect(envelope.payloadType, wire.PayloadTypeId.XEmbedTrayCommand);
      commands.add(envelope.payload as wire.XembedTrayCommand);
      return null;
    });
    final bridge = _startedBridge();
    try {
      expect(
        bridge.invokeXEmbedTrayAction(
          42,
          tray_model.SystemTrayAction.secondaryActivate,
          const Offset(-320, 1440),
        ),
        isTrue,
      );
      expect(
        bridge.invokeXEmbedTrayAction(
          0,
          tray_model.SystemTrayAction.activate,
          Offset.zero,
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);

      expect(commands, hasLength(1));
      expect(
        commands.single.kind,
        wire.XembedTrayCommandKind.SecondaryActivate,
      );
      expect(commands.single.windowId, 42);
      expect(commands.single.x, -320);
      expect(commands.single.y, 1440);
    } finally {
      bridge.dispose();
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
    }
  });

  test('audio writes carry an acknowledgement serial', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ByteData? sent;
    messenger.setMockMessageHandler('denial/audio', (message) async {
      sent = message;
      return null;
    });
    final bridge = _startedBridge();
    try {
      bridge.setAudioLevel(73, requestSerial: 0x10203040);
      await Future<void>.delayed(Duration.zero);

      expect(sent, isNotNull);
      expect(sent!.lengthInBytes, 6);
      expect(sent!.getUint8(0), 1);
      expect(sent!.getUint8(1), 73);
      expect(sent!.getUint32(2, Endian.little), 0x10203040);
    } finally {
      bridge.dispose();
      messenger.setMockMessageHandler('denial/audio', null);
    }
  });

  test('authoritative audio states are streamed and complete reads', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler('denial/audio', (_) async => null);
    final bridge = _startedBridge();
    final states = <DenialAudioState>[];
    final subscription = bridge.audioStates.listen(states.add);
    try {
      final read = bridge.readAudioLevel();
      final payload = ByteData(5)
        ..setUint8(0, 64)
        ..setUint32(1, 91, Endian.little);
      await messenger.handlePlatformMessage(
        'denial/audio_state',
        payload,
        null,
      );

      expect(await read, 0.64);
      expect(states, hasLength(1));
      expect(states.single.level, 0.64);
      expect(states.single.requestSerial, 91);
      expect(states.single.completesRead, isTrue);
    } finally {
      await subscription.cancel();
      bridge.dispose();
      messenger.setMockMessageHandler('denial/audio', null);
    }
  });

  test(
    'application audio stream commands use the native audio channel',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <ByteData>[];
      messenger.setMockMessageHandler('denial/audio', (message) async {
        sent.add(message!);
        return null;
      });
      final bridge = _startedBridge();
      try {
        bridge.requestAudioStreams();
        bridge.setAudioStreamLevel(0x10203040, 67);
        await Future<void>.delayed(Duration.zero);

        expect(sent, hasLength(2));
        expect(sent[0].lengthInBytes, 1);
        expect(sent[0].getUint8(0), 2);
        expect(sent[1].lengthInBytes, 6);
        expect(sent[1].getUint8(0), 3);
        expect(sent[1].getUint32(1, Endian.little), 0x10203040);
        expect(sent[1].getUint8(5), 67);
      } finally {
        bridge.dispose();
        messenger.setMockMessageHandler('denial/audio', null);
      }
    },
  );

  test('application audio stream snapshots preserve names and state', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    final snapshots = <List<DenialAudioStream>>[];
    final subscription = bridge.audioStreamStates.listen(snapshots.add);
    try {
      final payload = ByteData(34)
        ..setUint32(0, 2, Endian.little)
        ..setUint32(4, 41, Endian.little)
        ..setUint8(8, 72)
        ..setUint8(9, 0)
        ..setUint16(10, 7, Endian.little)
        ..buffer.asUint8List().setRange(12, 19, 'Firefox'.codeUnits)
        ..setUint32(19, 99, Endian.little)
        ..setUint8(23, 18)
        ..setUint8(24, 1)
        ..setUint16(25, 7, Endian.little)
        ..buffer.asUint8List().setRange(27, 34, 'Spotify'.codeUnits);
      await messenger.handlePlatformMessage(
        'denial/audio_streams_state',
        payload,
        null,
      );

      expect(snapshots, hasLength(1));
      expect(snapshots.single, hasLength(2));
      expect(snapshots.single[0].id, 41);
      expect(snapshots.single[0].name, 'Firefox');
      expect(snapshots.single[0].level, 0.72);
      expect(snapshots.single[0].muted, isFalse);
      expect(snapshots.single[1].id, 99);
      expect(snapshots.single[1].name, 'Spotify');
      expect(snapshots.single[1].level, 0.18);
      expect(snapshots.single[1].muted, isTrue);
    } finally {
      await subscription.cancel();
      bridge.dispose();
    }
  });

  test(
    'brightness states preserve the target monitor and native level',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final bridge = _startedBridge();
      final states = <DenialBrightnessState>[];
      final subscription = bridge.brightnessStates.listen(states.add);
      try {
        final payload = ByteData(9)
          ..setInt64(0, 0x100000002, Endian.little)
          ..setUint8(8, 47);
        await messenger.handlePlatformMessage(
          'denial/brightness_state',
          payload,
          null,
        );

        expect(states, hasLength(1));
        expect(states.single.monitorId, 0x100000002);
        expect(states.single.level, 0.47);
      } finally {
        await subscription.cancel();
        bridge.dispose();
      }
    },
  );

  test('malformed lazy payload is contained by the message handler', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final bridge = _startedBridge();
    try {
      final valid = _windowSnapshot();
      final truncated = Uint8List.sublistView(valid, 0, valid.length ~/ 2);
      await expectLater(
        messenger.handlePlatformMessage(
          wire.denialWireToFlutterChannel,
          ByteData.sublistView(truncated),
          null,
        ),
        completes,
      );
    } finally {
      bridge.dispose();
    }
  });

  test(
    'dispose rejects window requests and resolves nullable requests',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(
        wire.denialWireToNativeChannel,
        (_) async => null,
      );
      final bridge = _startedBridge();
      final windows = bridge.listWindows(const <DenialWindow>[]);
      final display = bridge.getDisplayLayout();
      final windowsExpectation = expectLater(
        windows,
        throwsA(isA<StateError>()),
      );

      bridge.dispose();

      await windowsExpectation;
      await expectLater(display, completion(isNull));
      messenger.setMockMessageHandler(wire.denialWireToNativeChannel, null);
    },
  );
}

List<String> _decodeSystemArguments(ByteData data) {
  final count = data.getUint32(9, Endian.little);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  var offset = 13;
  final arguments = <String>[];
  for (var index = 0; index < count; index += 1) {
    final length = data.getUint32(offset, Endian.little);
    offset += 4;
    arguments.add(utf8.decode(bytes.sublist(offset, offset + length)));
    offset += length;
  }
  expect(offset, data.lengthInBytes);
  return arguments;
}

DenialBridge _startedBridge() {
  return DenialBridge()
    ..start(onWindowsChanged: () {}, onWindowActivated: (_) {});
}

Future<void> _sendToFlutter(
  TestDefaultBinaryMessenger messenger,
  Uint8List bytes,
) async {
  await messenger.handlePlatformMessage(
    wire.denialWireToFlutterChannel,
    ByteData.sublistView(bytes),
    null,
  );
}

Uint8List _windowResponse({required int requestId}) {
  return _envelope(
    wire.PayloadTypeId.WindowResponse,
    wire.WindowResponseObjectBuilder(
      kind: wire.WindowResponseKind.Windows,
      success: true,
      windows: wire.WindowSnapshotObjectBuilder(
        windows: <wire.WindowObjectBuilder>[_window()],
      ),
    ),
    requestId: requestId,
  );
}

Uint8List _displayResponse({required int requestId}) {
  return _envelope(
    wire.PayloadTypeId.WindowResponse,
    wire.WindowResponseObjectBuilder(
      kind: wire.WindowResponseKind.DisplayLayout,
      success: true,
      displayLayout: wire.DisplayLayoutObjectBuilder(
        epoch: 0x100000001,
        globalOrigin: wire.WirePointObjectBuilder(x: -10, y: 5),
        logicalSize: wire.WireSizeObjectBuilder(width: 1920, height: 1080),
        pixelSize: wire.WireSizeObjectBuilder(width: 3840, height: 2160),
        engineScale: 2,
        tickerMonitorId: 4,
        systemBarMonitorId: 4,
        systemBarMonitorIds: <int>[4],
        systemBarSide: wire.SystemBarSide.Top,
        systemBarThickness: 32,
        outputs: <wire.DisplayOutputObjectBuilder>[
          wire.DisplayOutputObjectBuilder(
            monitorId: 4,
            name: 'eDP-1',
            logicalRect: wire.WireRectObjectBuilder(
              x: -10,
              y: 5,
              width: 1920,
              height: 1080,
            ),
            pixelSize: wire.WireSizeObjectBuilder(width: 3840, height: 2160),
            sourceRect: wire.WireRectObjectBuilder(
              x: 0,
              y: 0,
              width: 3840,
              height: 2160,
            ),
            scale: 2,
            refreshRate: 120,
          ),
        ],
      ),
    ),
    requestId: requestId,
  );
}

Uint8List _settingsDocumentResponse({
  required int requestId,
  required int revision,
  required String document,
}) {
  return _envelope(
    wire.PayloadTypeId.SettingsResponse,
    wire.SettingsResponseObjectBuilder(
      kind: wire.SettingsResponseKind.Document,
      success: true,
      revision: revision,
      document: document,
    ),
    requestId: requestId,
  );
}

Uint8List _keyboardSettingsResponse({
  required int requestId,
  required int revision,
  required int activeLayout,
  int repeatRateHz = 30,
}) {
  return _envelope(
    wire.PayloadTypeId.SettingsResponse,
    wire.SettingsResponseObjectBuilder(
      kind: wire.SettingsResponseKind.Keyboard,
      success: true,
      revision: revision,
      keyboard: wire.KeyboardConfigurationObjectBuilder(
        layouts: <wire.KeyboardLayoutObjectBuilder>[
          wire.KeyboardLayoutObjectBuilder(
            layout: 'us',
            variant: '',
            displayName: 'English (US)',
          ),
          wire.KeyboardLayoutObjectBuilder(
            layout: 'de',
            variant: 'nodeadkeys',
            displayName: 'German',
          ),
        ],
        options: const <String>['compose:menu'],
        repeatDelayMs: 450,
        repeatRateHz: repeatRateHz,
        activeLayout: activeLayout,
      ),
    ),
    requestId: requestId,
  );
}

Uint8List _inputDeviceCapabilitiesResponse({
  required int requestId,
  required bool hasTouchpad,
  int revision = 7,
  bool tapToClickEnabled = true,
  bool naturalScrollEnabled = false,
  double scrollSpeedFactor = 1,
}) {
  return _envelope(
    wire.PayloadTypeId.SettingsResponse,
    wire.SettingsResponseObjectBuilder(
      kind: wire.SettingsResponseKind.InputDevices,
      success: true,
      revision: revision,
      inputDevices: wire.InputDeviceCapabilitiesObjectBuilder(
        hasTouchpad: hasTouchpad,
        touchpad: wire.TouchpadConfigurationObjectBuilder(
          tapToClickEnabled: tapToClickEnabled,
          naturalScrollEnabled: naturalScrollEnabled,
          scrollSpeedFactor: scrollSpeedFactor,
        ),
      ),
    ),
    requestId: requestId,
  );
}

Uint8List _windowSnapshot() {
  return _envelope(
    wire.PayloadTypeId.WindowSnapshot,
    wire.WindowSnapshotObjectBuilder(
      windows: <wire.WindowObjectBuilder>[_window()],
    ),
  );
}

wire.WindowObjectBuilder _window() {
  return wire.WindowObjectBuilder(
    objectId: 0x100000000,
    objectKind: wire.ObjectKind.RootSurface,
    surfaceId: 0x200000000,
    windowId: 0x300000000,
    textureId: 7,
    title: 'Golden café 🐒',
    appId: 'dev.denial.golden',
    width: 1280,
    height: 960,
    surfaceX: 0.25,
    surfaceY: 1.5,
    surfaceWidth: 1280.5,
    surfaceHeight: 960.25,
    textureSourceX: 2.5,
    textureSourceY: 3.75,
    textureSourceWidth: 1275.5,
    textureSourceHeight: 955.25,
    geometryX: -12.5,
    geometryY: 4.75,
    geometryWidth: 640.5,
    geometryHeight: 480.25,
    monitorId: 4,
    transform: 0,
    scale120: 120,
    pinned: true,
  );
}

Uint8List _envelope(
  wire.PayloadTypeId type,
  dynamic payload, {
  int requestId = 0,
}) {
  return wire.EnvelopeObjectBuilder(
    protocolVersion: 1,
    sequence: 41,
    requestId: requestId,
    payloadType: type,
    payload: payload,
  ).toBytes('DENW');
}

ByteData _placementPacket({
  required int sequence,
  required DenialWindowPlacementPhase phase,
}) {
  return ByteData(80)
    ..setUint8(0, 0x44)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4e)
    ..setUint8(3, 0x50)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 2, Endian.little)
    ..setUint32(8, 80, Endian.little)
    ..setUint64(12, sequence, Endian.little)
    ..setUint64(20, 0x300000000, Endian.little)
    ..setInt64(28, 4, Endian.little)
    ..setInt64(36, 7, Endian.little)
    ..setUint8(44, phase.index)
    ..setUint8(45, DenialWindowPlacementChange.move.index)
    ..setFloat64(48, sequence.toDouble(), Endian.little)
    ..setFloat64(56, 4.75, Endian.little)
    ..setFloat64(64, 640.5, Endian.little)
    ..setFloat64(72, 480.25, Endian.little);
}

ByteData _dragIconPacket({required int sequence, bool active = true}) {
  return ByteData(128)
    ..setUint8(0, 0x44)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4e)
    ..setUint8(3, 0x44)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 3, Endian.little)
    ..setUint32(8, 128, Endian.little)
    ..setUint64(12, sequence, Endian.little)
    ..setUint32(20, active ? 1 : 0, Endian.little)
    ..setUint64(28, 0x200000004, Endian.little)
    ..setUint64(36, 7, Endian.little)
    ..setUint32(44, 320, Endian.little)
    ..setUint32(48, 240, Endian.little)
    ..setUint32(52, 0, Endian.little)
    ..setUint32(56, 120, Endian.little)
    ..setFloat64(64, -12.5, Endian.little)
    ..setFloat64(72, 8.25, Endian.little)
    ..setFloat64(80, 160, Endian.little)
    ..setFloat64(88, 120, Endian.little)
    ..setFloat64(96, 1, Endian.little)
    ..setFloat64(104, 2, Endian.little)
    ..setFloat64(112, 319, Endian.little)
    ..setFloat64(120, 238, Endian.little);
}

String _brightnessConnector(ByteData data) {
  final length = data.getUint16(10, Endian.little);
  return utf8.decode(
    Uint8List.view(data.buffer, data.offsetInBytes + 12, length),
  );
}

Uint8List _bytes(ByteData data) {
  return Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
}
