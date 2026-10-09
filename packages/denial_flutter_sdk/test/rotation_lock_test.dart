// Execution requires explicitly authorized Flutter development-engine testing.
import 'dart:async';
import 'dart:convert';

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:test/test.dart';

DenialSettingsDocument document(int revision, {bool locked = false}) =>
    DenialSettingsDocument(
      revision: revision,
      json: jsonEncode({
        'version': 28,
        'revision': revision,
        'rotationLockSupported': true,
        'rotationLock': {'enabled': locked, 'orientation': locked ? 90 : 0},
        'unrelated': revision,
      }),
    );

class TestBridge implements DenialBridge {
  final documents = StreamController<DenialSettingsDocument>.broadcast(
    sync: true,
  );
  late Future<DenialSettingsDocument> Function() read;
  late Future<DenialSettingsDocument> Function(int revision, String json) write;

  @override
  Stream<DenialSettingsDocument> get settingsDocuments => documents.stream;

  @override
  Future<DenialSettingsDocument> readSettingsDocument() => read();

  @override
  Future<DenialSettingsDocument> writeSettingsDocument({
    required int expectedRevision,
    required String document,
  }) => write(expectedRevision, document);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> drainMicrotasks() => Future<void>.delayed(Duration.zero);

ProviderContainer containerFor(TestBridge bridge) {
  final container = ProviderContainer(
    overrides: [denialBridgeProvider.overrideWithValue(bridge)],
  );
  container.listen(rotationLockProvider, (_, _) {});
  addTearDown(container.dispose);
  addTearDown(bridge.documents.close);
  return container;
}

void main() {
  test(
    'late seed failure cannot erase an authoritative locked snapshot',
    () async {
      final bridge = TestBridge();
      final seed = Completer<DenialSettingsDocument>();
      bridge.read = () => seed.future;
      final container = containerFor(bridge);
      bridge.documents.add(document(2, locked: true));
      await drainMicrotasks();
      seed.completeError(StateError('seed read failed'));
      await drainMicrotasks();
      final state = container.read(rotationLockProvider);
      expect(state.supported, isTrue);
      expect(state.locked, isTrue);
      expect(state.error, isNull);
    },
  );

  test(
    'locking waits for native acknowledgement and blocks repeated taps',
    () async {
      final bridge = TestBridge();
      bridge.read = () async => document(1);
      final response = Completer<DenialSettingsDocument>();
      var writes = 0;
      bridge.write = (revision, json) {
        writes++;
        expect(revision, 1);
        expect(jsonDecode(json)['rotationLock'], {'enabled': true});
        return response.future;
      };
      final container = containerFor(bridge);
      await drainMicrotasks();
      final controller = container.read(rotationLockProvider.notifier);
      final pending = controller.toggle();
      await drainMicrotasks();
      expect(container.read(rotationLockProvider).locked, isFalse);
      expect(container.read(rotationLockProvider).busy, isTrue);
      await controller.toggle();
      expect(writes, 1);
      response.complete(document(2, locked: true));
      await pending;
      expect(container.read(rotationLockProvider).locked, isTrue);
      expect(container.read(rotationLockProvider).busy, isFalse);
    },
  );

  test(
    'conflict retries merge only lock intent with latest document',
    () async {
      final bridge = TestBridge();
      var current = document(1);
      bridge.read = () async => current;
      var writes = 0;
      bridge.write = (revision, json) async {
        writes++;
        if (writes == 1) {
          current = document(3);
          throw StateError('revision conflict');
        }
        expect(revision, 3);
        final request = jsonDecode(json);
        expect(request['unrelated'], 3);
        expect(request['rotationLock'], {'enabled': true});
        return document(4, locked: true);
      };
      final container = containerFor(bridge);
      await drainMicrotasks();
      await container.read(rotationLockProvider.notifier).toggle();
      expect(writes, 2);
      expect(container.read(rotationLockProvider).locked, isTrue);
    },
  );

  test(
    'failed unlock retains last committed lock and reports failure',
    () async {
      final bridge = TestBridge();
      bridge.read = () async => document(1, locked: true);
      bridge.write = (_, _) async => throw StateError('cannot persist');
      final container = containerFor(bridge);
      await drainMicrotasks();
      await container.read(rotationLockProvider.notifier).toggle();
      final state = container.read(rotationLockProvider);
      expect(state.locked, isTrue);
      expect(state.busy, isFalse);
      expect(state.error, isA<StateError>());
    },
  );
}
