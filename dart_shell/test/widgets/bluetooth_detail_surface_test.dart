import 'dart:async';

import 'package:denial_dart_shell/src/services/bluetooth_service.dart';
import 'package:denial_dart_shell/src/state/bluetooth.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/connectivity/bluetooth_detail_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('surface distinguishes service loss and adapter loss',
      (tester) async {
    final backend = _FakeBluetoothBackend(
      const BluetoothSnapshot.unavailable(),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        bluetoothServiceProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await backend.dispose();
    });

    await tester.pumpWidget(_host(container));
    await tester.pump();
    expect(find.text('BlueZ is unavailable'), findsOneWidget);

    backend.emit(_snapshot(adapterAvailable: false));
    await tester.pump();
    expect(find.text('No Bluetooth adapter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('device actions and pairing secret remain one-shot',
      (tester) async {
    final backend = _FakeBluetoothBackend(_snapshot());
    final container = ProviderContainer(
      overrides: <Override>[
        bluetoothServiceProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await backend.dispose();
    });

    await tester.pumpWidget(_host(container, textScale: 1.25));
    await tester.pump();
    expect(find.text('Keyboard'), findsOneWidget);
    expect(find.text('Speaker'), findsNWidgets(2));

    await tester.tap(find.bySemanticsLabel('Pair Keyboard'));
    await tester.pump();
    expect(backend.pairCalls, 1);

    await tester.tap(find.bySemanticsLabel('Stop trusting Speaker'));
    await tester.pump();
    expect(backend.trustWrites, <bool>[false]);

    await tester.tap(find.bySemanticsLabel('Disconnect Speaker'));
    await tester.pump();
    expect(backend.disconnectCalls, 1);

    await tester.tap(find.bySemanticsLabel('Remove Speaker'));
    await tester.pump();
    expect(backend.removeCalls, 1);

    backend.expectedPairingResponse = '4829';
    backend.emitPairing(
      const BluetoothPairingRequest(
        id: 11,
        kind: BluetoothPairingRequestKind.pinCode,
        devicePath: '/org/bluez/hci0/dev_keyboard',
        address: '00:11:22:33:44:55',
        deviceName: 'Keyboard',
      ),
    );
    await tester.pump();
    expect(find.text('Enter the PIN for Keyboard'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), '4829');
    await tester.tap(find.text('Submit'));
    await tester.pump();

    expect(backend.pairingResponses, 1);
    expect(backend.pairingResponseMatched, isTrue);
    expect(find.byType(EditableText), findsNothing);
    expect(
      container.read(bluetoothProvider).toString(),
      isNot(contains('4829')),
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _host(
  ProviderContainer container, {
  double textScale = 1,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(
          size: const Size(620, 760),
          textScaler: TextScaler.linear(textScale),
        ),
        child: DefaultTextStyle(
          style: ShellText.base,
          child: SizedBox(
            width: 620,
            height: 760,
            child: BluetoothDetailSurface(onClose: _noop),
          ),
        ),
      ),
    ),
  );
}

void _noop() {}

class _FakeBluetoothBackend implements BluetoothBackend {
  _FakeBluetoothBackend(this._current);

  final StreamController<BluetoothSnapshot> _snapshots =
      StreamController<BluetoothSnapshot>.broadcast(sync: true);
  final StreamController<BluetoothPairingRequest?> _pairingRequests =
      StreamController<BluetoothPairingRequest?>.broadcast(sync: true);
  BluetoothSnapshot _current;
  BluetoothPairingRequest? _currentPairing;
  int pairCalls = 0;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int removeCalls = 0;
  int discoveryStarts = 0;
  int discoveryStops = 0;
  final List<bool> trustWrites = <bool>[];
  int pairingResponses = 0;
  String? expectedPairingResponse;
  bool pairingResponseMatched = false;

  @override
  BluetoothSnapshot get currentSnapshot => _current;

  @override
  BluetoothPairingRequest? get currentPairingRequest => _currentPairing;

  @override
  Stream<BluetoothSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<BluetoothPairingRequest?> get pairingRequests =>
      _pairingRequests.stream;

  void emit(BluetoothSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  void emitPairing(BluetoothPairingRequest? request) {
    _currentPairing = request;
    _pairingRequests.add(request);
  }

  @override
  Future<void> start() async => emit(_current);

  @override
  Future<void> refresh() async => emit(_current);

  @override
  Future<void> setPowered(bool powered) async {}

  @override
  Future<void> startDiscovery() async {
    discoveryStarts += 1;
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStops += 1;
  }

  @override
  Future<void> pair(BluetoothDeviceInfo device) async {
    pairCalls += 1;
  }

  @override
  Future<void> setTrusted(
    BluetoothDeviceInfo device,
    bool trusted,
  ) async {
    trustWrites.add(trusted);
  }

  @override
  Future<void> connect(BluetoothDeviceInfo device) async {
    connectCalls += 1;
  }

  @override
  Future<void> disconnect(BluetoothDeviceInfo device) async {
    disconnectCalls += 1;
  }

  @override
  Future<void> remove(BluetoothDeviceInfo device) async {
    removeCalls += 1;
  }

  @override
  void respondToPairing(
    int requestId, {
    required bool accepted,
    String? response,
  }) {
    pairingResponses += 1;
    pairingResponseMatched = accepted &&
        requestId == _currentPairing?.id &&
        response == expectedPairingResponse;
    emitPairing(null);
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _pairingRequests.close();
  }
}

BluetoothSnapshot _snapshot({bool adapterAvailable = true}) {
  return BluetoothSnapshot(
    serviceAvailable: true,
    available: adapterAvailable,
    adapterPath: adapterAvailable ? '/org/bluez/hci0' : null,
    adapterName: adapterAvailable ? 'Test adapter' : '',
    powered: adapterAvailable,
    discovering: false,
    pairable: adapterAvailable,
    devices: adapterAvailable
        ? <BluetoothDeviceInfo>[
            const BluetoothDeviceInfo(
              objectPath: '/org/bluez/hci0/dev_keyboard',
              adapterPath: '/org/bluez/hci0',
              address: '00:11:22:33:44:55',
              name: 'Keyboard',
              icon: 'input-keyboard',
              connected: false,
              paired: false,
              trusted: false,
              blocked: false,
              servicesResolved: false,
              signalStrength: -44,
            ),
            const BluetoothDeviceInfo(
              objectPath: '/org/bluez/hci0/dev_speaker',
              adapterPath: '/org/bluez/hci0',
              address: 'AA:BB:CC:DD:EE:FF',
              name: 'Speaker',
              icon: 'audio-card',
              connected: true,
              paired: true,
              trusted: true,
              blocked: false,
              servicesResolved: true,
              signalStrength: -35,
            ),
          ]
        : const <BluetoothDeviceInfo>[],
  );
}
