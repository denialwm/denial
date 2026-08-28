import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../models/system_tray_item.dart';
import 'background_worker.dart';

part 'status_notifier_backend.dart';
part 'status_notifier_endpoint.dart';
part 'status_notifier_models.dart';
part 'status_notifier_worker.dart';

/// Hosts the freedesktop/KDE StatusNotifier protocol used by AppIndicator and
/// modern Linux tray applications without touching Flutter's UI isolate.
class StatusNotifierService {
  static const String watcherName = 'org.kde.StatusNotifierWatcher';
  static const String watcherPath = '/StatusNotifierWatcher';
  static const String watcherInterface = 'org.kde.StatusNotifierWatcher';
  static const String standardWatcherName =
      'org.freedesktop.StatusNotifierWatcher';
  static const String standardWatcherInterface =
      'org.freedesktop.StatusNotifierWatcher';
  static const String itemInterface = 'org.kde.StatusNotifierItem';
  static const String standardItemInterface =
      'org.freedesktop.StatusNotifierItem';
  static const String menuInterface = 'com.canonical.dbusmenu';
  static const List<String> itemInterfaces = <String>[
    itemInterface,
    standardItemInterface,
  ];

  factory StatusNotifierService({DBusClient? client}) {
    return client == null
        ? StatusNotifierService._isolated()
        : StatusNotifierService._local(client);
  }

  StatusNotifierService._isolated()
    : _localBackend = null,
      _worker = BackgroundWorker(
        entrypoint: _statusNotifierWorkerMain,
        debugName: 'denial-status-notifier-worker',
      );

  StatusNotifierService._local(DBusClient client)
    : _localBackend = _StatusNotifierDbusBackend(client),
      _worker = null;

  final _StatusNotifierDbusBackend? _localBackend;
  final BackgroundWorker? _worker;
  final StreamController<List<SystemTrayItem>> _snapshots =
      StreamController<List<SystemTrayItem>>.broadcast(sync: true);

  StreamSubscription<List<SystemTrayItem>>? _localSnapshots;
  ReceivePort? _workerEvents;
  StreamSubscription<Object?>? _workerEventSubscription;
  List<SystemTrayItem> _current = const <SystemTrayItem>[];
  bool _started = false;
  bool _disposed = false;

  Stream<List<SystemTrayItem>> get snapshots => _snapshots.stream;

  List<SystemTrayItem> get current => _current;

  @visibleForTesting
  bool get isolatesDbus => _worker != null;

  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    final local = _localBackend;
    if (local != null) {
      _localSnapshots = local.snapshots.listen(_publish);
      try {
        await local.start();
        _publish(local.current);
      } on Object {
        _started = false;
        await _localSnapshots?.cancel();
        _localSnapshots = null;
        rethrow;
      }
      return;
    }

    final events = ReceivePort();
    _workerEvents = events;
    _workerEventSubscription = events.listen((message) {
      try {
        _publish(_decodeTrayItems(message));
      } on Object {
        // A malformed worker event is ignored without affecting later state.
      }
    });
    try {
      final initial = await _worker!.invoke<List<SystemTrayItem>>(
        operation: _StatusNotifierWorkerOperation.start,
        payload: events.sendPort,
        decode: _decodeTrayItems,
      );
      _publish(initial);
    } on Object {
      _started = false;
      await _closeWorkerEvents();
      rethrow;
    }
  }

  Future<bool> invoke(
    SystemTrayItem item,
    SystemTrayAction action,
    Offset position,
  ) {
    final local = _localBackend;
    if (local != null) {
      return local.invoke(item.id, action, position.dx, position.dy);
    }
    return _worker!.invoke<bool>(
      operation: _StatusNotifierWorkerOperation.invoke,
      payload: <Object?>[item.id, action.index, position.dx, position.dy],
      decode: (response) => response == true,
    );
  }

  Future<List<SystemTrayMenuEntry>?> loadMenu(SystemTrayItem item) {
    final local = _localBackend;
    if (local != null) {
      return local.loadMenu(item.id);
    }
    return _worker!.invoke<List<SystemTrayMenuEntry>?>(
      operation: _StatusNotifierWorkerOperation.loadMenu,
      payload: item.id,
      decode: _decodeMenuEntries,
    );
  }

  Future<bool> activateMenuEntry(SystemTrayItem item, int entryId) {
    final local = _localBackend;
    if (local != null) {
      return local.activateMenuEntry(item.id, entryId);
    }
    return _worker!.invoke<bool>(
      operation: _StatusNotifierWorkerOperation.activateMenuEntry,
      payload: <Object?>[item.id, entryId],
      decode: (response) => response == true,
    );
  }

  void _publish(List<SystemTrayItem> items) {
    if (_disposed || listEquals(_current, items)) {
      return;
    }
    _current = List<SystemTrayItem>.unmodifiable(items);
    if (!_snapshots.isClosed) {
      _snapshots.add(_current);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _localSnapshots?.cancel();
    _localSnapshots = null;
    final local = _localBackend;
    if (local != null) {
      await local.dispose();
    } else {
      try {
        if (_started) {
          await _worker!.invoke<void>(
            operation: _StatusNotifierWorkerOperation.dispose,
            decode: (_) {},
          );
        }
      } on Object {
        // The worker may already have exited; close() remains authoritative.
      }
      await _worker!.close();
      await _closeWorkerEvents();
    }
    await _snapshots.close();
  }

  Future<void> _closeWorkerEvents() async {
    await _workerEventSubscription?.cancel();
    _workerEventSubscription = null;
    _workerEvents?.close();
    _workerEvents = null;
  }
}

/// Session-bus implementation. Production constructs and owns this object
/// exclusively inside [_statusNotifierWorkerMain]. An injected client keeps
/// deterministic protocol tests possible without crossing isolate boundaries.
