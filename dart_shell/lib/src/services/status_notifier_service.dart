import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../models/system_tray_item.dart';
import 'background_worker.dart';

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
class _StatusNotifierDbusBackend {
  _StatusNotifierDbusBackend(this._client)
    : _watcher = StatusNotifierWatcherEndpoint();

  static const String watcherName = StatusNotifierService.watcherName;
  static const String watcherPath = StatusNotifierService.watcherPath;
  static const String watcherInterface = StatusNotifierService.watcherInterface;
  static const String standardWatcherName =
      StatusNotifierService.standardWatcherName;
  static const String menuInterface = StatusNotifierService.menuInterface;
  static const List<String> itemInterfaces =
      StatusNotifierService.itemInterfaces;
  static const Duration _readTimeout = Duration(seconds: 2);
  static const Duration _methodTimeout = Duration(seconds: 4);
  static const Duration _signalCoalesce = Duration(milliseconds: 45);
  static const int _maxItems = 64;
  static const int _maxMenuItems = 256;
  static const int _maxMenuDepth = 5;

  final DBusClient _client;
  final StatusNotifierWatcherEndpoint _watcher;
  final StreamController<List<SystemTrayItem>> _snapshots =
      StreamController<List<SystemTrayItem>>.broadcast(sync: true);
  final Map<String, _StatusNotifierRegistration> _registrations = {};
  final Map<String, SystemTrayItem> _items = {};
  final Map<String, String> _itemInterfaces = {};
  final Map<String, Map<String, DBusValue>> _itemProperties = {};
  final Map<String, SystemTrayIconPixmap?> _normalPixmaps = {};
  final Map<String, SystemTrayIconPixmap?> _attentionPixmaps = {};
  final Map<String, _PendingStatusNotifierRefresh> _pendingRefreshes = {};
  List<SystemTrayItem> _lastSnapshot = const <SystemTrayItem>[];

  final List<StreamSubscription<DBusSignal>> _itemSignals = [];
  StreamSubscription<DBusSignal>? _watcherSignals;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerChanges;
  Timer? _signalTimer;
  Timer? _externalWatcherTimer;
  bool _ownsWatcher = false;
  bool _started = false;
  bool _disposed = false;
  bool _drainingRefreshes = false;

  Stream<List<SystemTrayItem>> get snapshots => _snapshots.stream;

  List<SystemTrayItem> get current => _orderedItems();

  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _watcher.onRegisterItem = _registerFromMethod;
    _watcher.onRegisterHost = (_) async {
      _watcher.setHostRegistered(true);
      await _watcher.emitHostRegistered();
    };
    await _client.registerObject(_watcher);
    final watcherReply = await _client.requestName(
      watcherName,
      flags: const {DBusRequestNameFlag.doNotQueue},
    );
    _ownsWatcher =
        watcherReply == DBusRequestNameReply.primaryOwner ||
        watcherReply == DBusRequestNameReply.alreadyOwner;

    final hostName = 'org.kde.StatusNotifierHost.Denial${pid.toString()}';
    await _client.requestName(
      hostName,
      flags: const {DBusRequestNameFlag.doNotQueue},
    );

    // Subscribe before importing registrations from an existing watcher so
    // item changes cannot race the initial asynchronous property reads.
    for (final interface in itemInterfaces) {
      _itemSignals.add(
        DBusSignalStream(
          _client,
          interface: interface,
        ).listen(_handleItemSignal, onError: (_) => _scheduleAllRefreshes()),
      );
    }
    _itemSignals.add(
      DBusSignalStream(
        _client,
        interface: 'org.freedesktop.DBus.Properties',
        name: 'PropertiesChanged',
      ).listen(
        _handlePropertiesChanged,
        onError: (_) => _scheduleAllRefreshes(),
      ),
    );
    _ownerChanges = _client.nameOwnerChanged.listen(_handleOwnerChanged);

    if (_ownsWatcher) {
      await _client.requestName(
        standardWatcherName,
        flags: const {DBusRequestNameFlag.doNotQueue},
      );
      await _client.requestName(
        'org.freedesktop.StatusNotifierHost-Denial${pid.toString()}',
        flags: const {DBusRequestNameFlag.doNotQueue},
      );
      _watcher.setHostRegistered(true);
      await _watcher.emitHostRegistered();
    } else {
      await _registerWithExternalWatcher(hostName);
    }
  }

  Future<void> _registerWithExternalWatcher(String hostName) async {
    final object = DBusRemoteObject(
      _client,
      name: watcherName,
      path: DBusObjectPath(watcherPath),
    );
    await object
        .callMethod(
          watcherInterface,
          'RegisterStatusNotifierHost',
          <DBusValue>[DBusString(hostName)],
          replySignature: DBusSignature(''),
        )
        .timeout(_methodTimeout);
    _watcherSignals = DBusSignalStream(
      _client,
      sender: watcherName,
      path: DBusObjectPath(watcherPath),
      interface: watcherInterface,
    ).listen((_) => _scheduleExternalWatcherRefresh());
    await _refreshExternalWatcher(object);
  }

  void _scheduleExternalWatcherRefresh() {
    if (_disposed || _ownsWatcher) {
      return;
    }
    _externalWatcherTimer?.cancel();
    _externalWatcherTimer = Timer(_signalCoalesce, () {
      _externalWatcherTimer = null;
      unawaited(
        _refreshExternalWatcher(
          DBusRemoteObject(
            _client,
            name: watcherName,
            path: DBusObjectPath(watcherPath),
          ),
        ),
      );
    });
  }

  Future<void> _refreshExternalWatcher(DBusRemoteObject object) async {
    try {
      final value = await object
          .getProperty(
            watcherInterface,
            'RegisteredStatusNotifierItems',
            signature: DBusSignature('as'),
          )
          .timeout(_readTimeout);
      final addresses = value.asStringArray().take(_maxItems).toSet();
      for (final address in addresses) {
        await _registerAddress(address, sender: null, emitSignal: false);
      }
      final removed = _registrations.values
          .where((registration) => !addresses.contains(registration.address))
          .toList(growable: false);
      for (final registration in removed) {
        _registrations.remove(registration.id);
        _items.remove(registration.id);
        _itemInterfaces.remove(registration.id);
        _itemProperties.remove(registration.id);
        _normalPixmaps.remove(registration.id);
        _attentionPixmaps.remove(registration.id);
        _pendingRefreshes.remove(registration.id);
      }
      if (removed.isNotEmpty) {
        _emit();
      }
    } on Object {
      // The owner-change stream retries if the external watcher restarts.
    }
  }

  Future<void> _registerFromMethod(String address, String? sender) {
    return _registerAddress(address, sender: sender, emitSignal: true);
  }

  Future<void> _registerAddress(
    String address, {
    required String? sender,
    required bool emitSignal,
  }) async {
    if (_disposed || _registrations.length >= _maxItems) {
      return;
    }
    final parsed = _parseRegistration(address, sender: sender);
    if (parsed == null || _registrations.containsKey(parsed.id)) {
      return;
    }
    String? owner;
    try {
      owner = await _client.getNameOwner(parsed.busName).timeout(_readTimeout);
    } on Object {
      return;
    }
    if (owner == null || owner.isEmpty || _disposed) {
      return;
    }
    if (_registrations.values.any(
      (registration) =>
          registration.owner == owner && registration.path == parsed.path,
    )) {
      return;
    }
    final registration = parsed.withOwner(owner);
    _registrations[registration.id] = registration;
    if (_ownsWatcher) {
      _watcher.setRegisteredItems(
        _registrations.values.map((item) => item.address),
      );
      if (emitSignal) {
        await _watcher.emitItemRegistered(registration.address);
      }
    }
    _scheduleItemRefresh(registration.id, full: true, immediate: true);
  }

  void _handleItemSignal(DBusSignal signal) {
    final registration = _registrationForSignal(signal);
    final properties = _itemSignalProperties[signal.name];
    if (registration == null || properties == null) {
      return;
    }
    _itemInterfaces[registration.id] = signal.interface;
    _scheduleItemRefresh(registration.id, properties: properties);
  }

  void _handlePropertiesChanged(DBusSignal signal) {
    final registration = _registrationForSignal(signal);
    if (registration == null || signal.signature != DBusSignature('sa{sv}as')) {
      return;
    }
    try {
      final changed = DBusPropertiesChangedSignal(signal);
      if (!itemInterfaces.contains(changed.propertiesInterface)) {
        return;
      }
      _itemInterfaces[registration.id] = changed.propertiesInterface;
      final properties = _itemProperties.putIfAbsent(
        registration.id,
        () => <String, DBusValue>{},
      );
      var updated = false;
      for (final entry in changed.changedProperties.entries) {
        if (_knownItemProperties.contains(entry.key)) {
          properties[entry.key] = entry.value;
          updated = true;
        }
      }
      if (updated) {
        _updateItem(registration);
      }
      final invalidated = changed.invalidatedProperties
          .where(_knownItemProperties.contains)
          .toSet();
      if (invalidated.isNotEmpty) {
        _scheduleItemRefresh(registration.id, properties: invalidated);
      }
    } on Object {
      _scheduleItemRefresh(registration.id, full: true);
    }
  }

  _StatusNotifierRegistration? _registrationForSignal(DBusSignal signal) {
    final sender = signal.sender;
    if (sender == null) {
      return null;
    }
    for (final registration in _registrations.values) {
      if (registration.owner == sender &&
          registration.path == signal.path.value) {
        return registration;
      }
    }
    return null;
  }

  void _handleOwnerChanged(DBusNameOwnerChangedEvent event) {
    if (!_ownsWatcher && event.name == watcherName && event.newOwner != null) {
      _scheduleExternalWatcherRefresh();
    }
    if (event.newOwner != null) {
      return;
    }
    final removed = _registrations.values
        .where((item) => item.busName == event.name || item.owner == event.name)
        .toList(growable: false);
    for (final registration in removed) {
      _registrations.remove(registration.id);
      _items.remove(registration.id);
      _itemInterfaces.remove(registration.id);
      _itemProperties.remove(registration.id);
      _normalPixmaps.remove(registration.id);
      _attentionPixmaps.remove(registration.id);
      _pendingRefreshes.remove(registration.id);
      if (_ownsWatcher) {
        unawaited(_watcher.emitItemUnregistered(registration.address));
      }
    }
    if (removed.isNotEmpty) {
      _watcher.setRegisteredItems(
        _registrations.values.map((item) => item.address),
      );
      _emit();
    }
  }

  void _scheduleAllRefreshes() {
    for (final registration in _registrations.values) {
      _scheduleItemRefresh(registration.id, full: true);
    }
  }

  void _scheduleItemRefresh(
    String registrationId, {
    Set<String> properties = const <String>{},
    bool full = false,
    bool immediate = false,
  }) {
    if (_disposed) {
      return;
    }
    final pending = _pendingRefreshes.putIfAbsent(
      registrationId,
      _PendingStatusNotifierRefresh.new,
    );
    if (full) {
      pending.full = true;
      pending.properties.clear();
    } else if (!pending.full) {
      pending.properties.addAll(
        properties.where(_knownItemProperties.contains),
      );
    }
    if (immediate && _signalTimer != null) {
      _signalTimer!.cancel();
      _signalTimer = null;
    }
    _signalTimer ??= Timer(immediate ? Duration.zero : _signalCoalesce, () {
      _signalTimer = null;
      unawaited(_drainRefreshes());
    });
  }

  Future<void> _drainRefreshes() async {
    if (_disposed || _drainingRefreshes) {
      return;
    }
    _drainingRefreshes = true;
    try {
      while (_pendingRefreshes.isNotEmpty && !_disposed) {
        final pending = Map<String, _PendingStatusNotifierRefresh>.of(
          _pendingRefreshes,
        );
        _pendingRefreshes.clear();
        await Future.wait(<Future<void>>[
          for (final entry in pending.entries)
            if (_registrations[entry.key] case final registration?)
              entry.value.full
                  ? _refreshAllProperties(registration)
                  : _refreshProperties(registration, entry.value.properties),
        ]);
      }
    } finally {
      _drainingRefreshes = false;
    }
  }

  Future<void> _refreshAllProperties(
    _StatusNotifierRegistration registration,
  ) async {
    final object = _remoteItem(registration);
    final preferred = _itemInterfaces[registration.id];
    final interfaces = <String>{?preferred, ...itemInterfaces};
    for (final interface in interfaces) {
      try {
        final properties = await object
            .getAllProperties(interface)
            .timeout(_readTimeout);
        _itemInterfaces[registration.id] = interface;
        _itemProperties[registration.id] = Map<String, DBusValue>.of(
          properties,
        );
        _updateItem(registration);
        return;
      } on Object {
        continue;
      }
    }
  }

  Future<void> _refreshProperties(
    _StatusNotifierRegistration registration,
    Set<String> propertyNames,
  ) async {
    if (propertyNames.isEmpty || _disposed) {
      return;
    }
    final object = _remoteItem(registration);
    final preferred = _itemInterfaces[registration.id];
    final interfaces = <String>{?preferred, ...itemInterfaces};
    for (final interface in interfaces) {
      final entries = await Future.wait(<Future<MapEntry<String, DBusValue>?>>[
        for (final property in propertyNames)
          _readProperty(object, interface, property),
      ]);
      final resolved = entries.whereType<MapEntry<String, DBusValue>>();
      if (resolved.isEmpty) {
        continue;
      }
      _itemInterfaces[registration.id] = interface;
      _itemProperties
          .putIfAbsent(registration.id, () => <String, DBusValue>{})
          .addEntries(resolved);
      _updateItem(registration);
      return;
    }
  }

  Future<MapEntry<String, DBusValue>?> _readProperty(
    DBusRemoteObject object,
    String interface,
    String property,
  ) async {
    try {
      final value = await object
          .getProperty(interface, property)
          .timeout(_readTimeout);
      return MapEntry<String, DBusValue>(property, value);
    } on Object {
      return null;
    }
  }

  void _updateItem(_StatusNotifierRegistration registration) {
    final properties = _itemProperties[registration.id];
    if (properties == null || _disposed) {
      return;
    }
    if (properties.remove('IconPixmap') case final rawPixmap?) {
      _normalPixmaps[registration.id] = _bestPixmap(rawPixmap);
    }
    if (properties.remove('AttentionIconPixmap') case final rawPixmap?) {
      _attentionPixmaps[registration.id] = _bestPixmap(rawPixmap);
    }
    final status = _status(_string(properties['Status']));
    final attention = status == SystemTrayStatus.needsAttention;
    var pixmap = attention
        ? _attentionPixmaps[registration.id]
        : _normalPixmaps[registration.id];
    if (attention && pixmap == null) {
      pixmap = _normalPixmaps[registration.id];
    }
    var iconName = _boundedText(
      _string(properties[attention ? 'AttentionIconName' : 'IconName']),
      512,
    );
    if (attention && iconName.isEmpty) {
      iconName = _boundedText(_string(properties['IconName']), 512);
    }
    final itemId = _boundedText(_string(properties['Id']), 256);
    final rawTitle = _boundedText(_string(properties['Title']), 256);
    final title = rawTitle.isNotEmpty
        ? rawTitle
        : itemId.isNotEmpty
        ? itemId
        : registration.busName;
    final menuPath = _objectPath(properties['Menu']);
    _items[registration.id] = SystemTrayItem(
      id: registration.id,
      source: SystemTrayItemSource.statusNotifier,
      title: title,
      status: status,
      iconName: iconName,
      iconThemePath: _boundedText(_string(properties['IconThemePath']), 4096),
      iconPixmap: pixmap,
      menuAvailable: menuPath != null && menuPath != '/',
      primaryOpensMenu: _boolean(properties['ItemIsMenu']),
      menuPath: menuPath ?? '',
    );
    _emit();
  }

  Future<bool> invoke(
    String itemId,
    SystemTrayAction action,
    double positionX,
    double positionY,
  ) async {
    final registration = _registrations[itemId];
    if (registration == null || _disposed) {
      return false;
    }
    final method = switch (action) {
      SystemTrayAction.activate => 'Activate',
      SystemTrayAction.secondaryActivate => 'SecondaryActivate',
      SystemTrayAction.contextMenu => 'ContextMenu',
    };
    final x = positionX.round().clamp(-0x80000000, 0x7fffffff);
    final y = positionY.round().clamp(-0x80000000, 0x7fffffff);
    final preferred = _itemInterfaces[registration.id];
    final interfaces = <String>{?preferred, ...itemInterfaces};
    for (final interface in interfaces) {
      try {
        await _remoteItem(registration)
            .callMethod(interface, method, <DBusValue>[
              DBusInt32(x),
              DBusInt32(y),
            ], replySignature: DBusSignature(''))
            .timeout(_methodTimeout);
        _itemInterfaces[registration.id] = interface;
        return true;
      } on Object {
        continue;
      }
    }
    _scheduleItemRefresh(registration.id, full: true, immediate: true);
    return false;
  }

  Future<List<SystemTrayMenuEntry>?> loadMenu(String itemId) async {
    final registration = _registrations[itemId];
    final item = _items[itemId];
    if (registration == null ||
        item == null ||
        _disposed ||
        !item.menuAvailable ||
        item.menuPath.isEmpty ||
        item.menuPath == '/') {
      return null;
    }
    DBusObjectPath path;
    try {
      path = DBusObjectPath(item.menuPath);
    } on Object {
      return null;
    }
    final object = DBusRemoteObject(
      _client,
      name: registration.busName,
      path: path,
    );
    try {
      await object
          .callMethod(menuInterface, 'AboutToShow', const <DBusValue>[
            DBusInt32(0),
          ], replySignature: DBusSignature('b'))
          .timeout(_methodTimeout);
    } on Object {
      // Some exporters omit AboutToShow even though their static layout is
      // otherwise usable.
    }
    try {
      final response = await object
          .callMethod(menuInterface, 'GetLayout', <DBusValue>[
            const DBusInt32(0),
            const DBusInt32(_maxMenuDepth),
            DBusArray.string(const <String>[
              'label',
              'enabled',
              'visible',
              'type',
              'children-display',
              'toggle-type',
              'toggle-state',
              'disposition',
            ]),
          ], replySignature: DBusSignature('u(ia{sv}av)'))
          .timeout(_methodTimeout);
      if (response.returnValues.length != 2) {
        return null;
      }
      final budget = _MenuBudget(_maxMenuItems);
      final root = _parseMenuEntry(
        response.returnValues[1],
        budget: budget,
        depth: 0,
      );
      if (root == null) {
        return null;
      }
      return List<SystemTrayMenuEntry>.unmodifiable(
        root.children.where((entry) => entry.visible),
      );
    } on Object {
      return null;
    }
  }

  Future<bool> activateMenuEntry(String itemId, int entryId) async {
    final registration = _registrations[itemId];
    final item = _items[itemId];
    if (registration == null ||
        item == null ||
        _disposed ||
        entryId <= 0 ||
        item.menuPath.isEmpty ||
        item.menuPath == '/') {
      return false;
    }
    try {
      await DBusRemoteObject(
            _client,
            name: registration.busName,
            path: DBusObjectPath(item.menuPath),
          )
          .callMethod(menuInterface, 'Event', <DBusValue>[
            DBusInt32(entryId),
            const DBusString('clicked'),
            const DBusVariant(DBusString('')),
            DBusUint32(DateTime.now().millisecondsSinceEpoch & 0xffffffff),
          ], replySignature: DBusSignature(''))
          .timeout(_methodTimeout);
      return true;
    } on Object {
      return false;
    }
  }

  DBusRemoteObject _remoteItem(_StatusNotifierRegistration registration) {
    return DBusRemoteObject(
      _client,
      name: registration.busName,
      path: DBusObjectPath(registration.path),
    );
  }

  List<SystemTrayItem> _orderedItems() {
    final items = _items.values.toList(growable: false)
      ..sort((left, right) {
        final byStatus = _statusPriority(
          left.status,
        ).compareTo(_statusPriority(right.status));
        return byStatus != 0
            ? byStatus
            : left.title.toLowerCase().compareTo(right.title.toLowerCase());
      });
    return List<SystemTrayItem>.unmodifiable(items);
  }

  void _emit() {
    final next = _orderedItems();
    if (!_snapshots.isClosed && !listEquals(_lastSnapshot, next)) {
      _lastSnapshot = next;
      _snapshots.add(next);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _signalTimer?.cancel();
    _externalWatcherTimer?.cancel();
    _pendingRefreshes.clear();
    for (final subscription in _itemSignals) {
      await subscription.cancel();
    }
    await _watcherSignals?.cancel();
    await _ownerChanges?.cancel();
    await _client.unregisterObject(_watcher);
    await _snapshots.close();
    await _client.close();
  }
}

abstract final class _StatusNotifierWorkerOperation {
  static const int start = 1;
  static const int invoke = 2;
  static const int loadMenu = 3;
  static const int activateMenuEntry = 4;
  static const int dispose = 5;
}

@pragma('vm:entry-point')
void _statusNotifierWorkerMain(List<SendPort> bootstrap) {
  final host = _StatusNotifierWorkerHost();
  serveBackgroundWorker(bootstrap, host.handle);
}

/// Owns every D-Bus/native object in the worker isolate. Only bounded Dart
/// values cross back to the shell isolate.
class _StatusNotifierWorkerHost {
  _StatusNotifierDbusBackend? _backend;
  StreamSubscription<List<SystemTrayItem>>? _snapshots;
  SendPort? _events;

  FutureOr<Object?> handle(int operation, Object? payload) async {
    return switch (operation) {
      _StatusNotifierWorkerOperation.start => _start(payload),
      _StatusNotifierWorkerOperation.invoke => _invoke(payload),
      _StatusNotifierWorkerOperation.loadMenu => _loadMenu(payload),
      _StatusNotifierWorkerOperation.activateMenuEntry => _activate(payload),
      _StatusNotifierWorkerOperation.dispose => _dispose(),
      _ => throw UnsupportedError(
        'Unknown StatusNotifier worker operation $operation',
      ),
    };
  }

  Future<Object?> _start(Object? payload) async {
    if (payload is! SendPort) {
      throw const FormatException('StatusNotifier event port is missing');
    }
    final existing = _backend;
    if (existing != null) {
      _events = payload;
      return _encodeTrayItems(existing.current);
    }
    final backend = _StatusNotifierDbusBackend(DBusClient.session());
    _backend = backend;
    _events = payload;
    _snapshots = backend.snapshots.listen((items) {
      _events?.send(_encodeTrayItems(items));
    });
    try {
      await backend.start();
      return _encodeTrayItems(backend.current);
    } on Object {
      await _dispose();
      rethrow;
    }
  }

  Future<bool> _invoke(Object? payload) async {
    final backend = _requireBackend();
    if (payload is! List<Object?> ||
        payload.length != 4 ||
        payload[0] is! String ||
        payload[1] is! int ||
        payload[2] is! double ||
        payload[3] is! double) {
      throw const FormatException('Invalid StatusNotifier action');
    }
    final actionIndex = payload[1]! as int;
    if (actionIndex < 0 || actionIndex >= SystemTrayAction.values.length) {
      throw const FormatException('Invalid StatusNotifier action kind');
    }
    return backend.invoke(
      payload[0]! as String,
      SystemTrayAction.values[actionIndex],
      payload[2]! as double,
      payload[3]! as double,
    );
  }

  Future<Object?> _loadMenu(Object? payload) async {
    if (payload is! String) {
      throw const FormatException('Invalid StatusNotifier menu request');
    }
    final entries = await _requireBackend().loadMenu(payload);
    return entries == null ? null : _encodeMenuEntries(entries);
  }

  Future<bool> _activate(Object? payload) async {
    if (payload is! List<Object?> ||
        payload.length != 2 ||
        payload[0] is! String ||
        payload[1] is! int) {
      throw const FormatException('Invalid StatusNotifier menu action');
    }
    return _requireBackend().activateMenuEntry(
      payload[0]! as String,
      payload[1]! as int,
    );
  }

  _StatusNotifierDbusBackend _requireBackend() {
    return _backend ??
        (throw StateError('StatusNotifier worker has not been started'));
  }

  Future<Object?> _dispose() async {
    _events = null;
    await _snapshots?.cancel();
    _snapshots = null;
    final backend = _backend;
    _backend = null;
    await backend?.dispose();
    return null;
  }
}

List<Object?> _encodeTrayItems(List<SystemTrayItem> items) => <Object?>[
  for (final item in items) _encodeTrayItem(item),
];

List<Object?> _encodeTrayItem(SystemTrayItem item) {
  final pixmap = item.iconPixmap;
  return <Object?>[
    item.id,
    item.source.index,
    item.title,
    item.status.index,
    item.iconName,
    item.iconThemePath,
    pixmap == null
        ? null
        : <Object?>[
            pixmap.width,
            pixmap.height,
            TransferableTypedData.fromList(<Uint8List>[pixmap.rgba]),
          ],
    item.menuAvailable,
    item.primaryOpensMenu,
    item.menuPath,
  ];
}

List<SystemTrayItem> _decodeTrayItems(Object? response) {
  if (response is! List<Object?>) {
    throw const FormatException('Invalid StatusNotifier snapshot');
  }
  return List<SystemTrayItem>.unmodifiable(response.map(_decodeTrayItem));
}

SystemTrayItem _decodeTrayItem(Object? response) {
  if (response is! List<Object?> ||
      response.length != 10 ||
      response[0] is! String ||
      response[1] is! int ||
      response[2] is! String ||
      response[3] is! int ||
      response[4] is! String ||
      response[5] is! String ||
      response[7] is! bool ||
      response[8] is! bool ||
      response[9] is! String) {
    throw const FormatException('Invalid StatusNotifier item');
  }
  final sourceIndex = response[1]! as int;
  final statusIndex = response[3]! as int;
  if (sourceIndex < 0 ||
      sourceIndex >= SystemTrayItemSource.values.length ||
      statusIndex < 0 ||
      statusIndex >= SystemTrayStatus.values.length) {
    throw const FormatException('Invalid StatusNotifier item enum');
  }
  return SystemTrayItem(
    id: response[0]! as String,
    source: SystemTrayItemSource.values[sourceIndex],
    title: response[2]! as String,
    status: SystemTrayStatus.values[statusIndex],
    iconName: response[4]! as String,
    iconThemePath: response[5]! as String,
    iconPixmap: _decodeTrayPixmap(response[6]),
    menuAvailable: response[7]! as bool,
    primaryOpensMenu: response[8]! as bool,
    menuPath: response[9]! as String,
  );
}

SystemTrayIconPixmap? _decodeTrayPixmap(Object? response) {
  if (response == null) {
    return null;
  }
  if (response is! List<Object?> ||
      response.length != 3 ||
      response[0] is! int ||
      response[1] is! int ||
      response[2] is! TransferableTypedData) {
    throw const FormatException('Invalid StatusNotifier pixmap');
  }
  final width = response[0]! as int;
  final height = response[1]! as int;
  final rgba = (response[2]! as TransferableTypedData)
      .materialize()
      .asUint8List();
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw const FormatException('Invalid StatusNotifier pixmap dimensions');
  }
  return SystemTrayIconPixmap(width: width, height: height, rgba: rgba);
}

List<Object?> _encodeMenuEntries(List<SystemTrayMenuEntry> entries) =>
    <Object?>[for (final entry in entries) _encodeMenuEntry(entry)];

List<Object?> _encodeMenuEntry(SystemTrayMenuEntry entry) => <Object?>[
  entry.id,
  entry.label,
  entry.enabled,
  entry.visible,
  entry.separator,
  entry.toggleType.index,
  entry.toggleState,
  entry.destructive,
  _encodeMenuEntries(entry.children),
];

List<SystemTrayMenuEntry>? _decodeMenuEntries(Object? response) {
  if (response == null) {
    return null;
  }
  if (response is! List<Object?>) {
    throw const FormatException('Invalid StatusNotifier menu');
  }
  return List<SystemTrayMenuEntry>.unmodifiable(response.map(_decodeMenuEntry));
}

SystemTrayMenuEntry _decodeMenuEntry(Object? response) {
  if (response is! List<Object?> ||
      response.length != 9 ||
      response[0] is! int ||
      response[1] is! String ||
      response[2] is! bool ||
      response[3] is! bool ||
      response[4] is! bool ||
      response[5] is! int ||
      response[6] is! int ||
      response[7] is! bool) {
    throw const FormatException('Invalid StatusNotifier menu entry');
  }
  final toggleIndex = response[5]! as int;
  if (toggleIndex < 0 ||
      toggleIndex >= SystemTrayMenuToggleType.values.length) {
    throw const FormatException('Invalid StatusNotifier menu toggle');
  }
  return SystemTrayMenuEntry(
    id: response[0]! as int,
    label: response[1]! as String,
    enabled: response[2]! as bool,
    visible: response[3]! as bool,
    separator: response[4]! as bool,
    toggleType: SystemTrayMenuToggleType.values[toggleIndex],
    toggleState: response[6]! as int,
    destructive: response[7]! as bool,
    children: _decodeMenuEntries(response[8]) ?? const <SystemTrayMenuEntry>[],
  );
}

@visibleForTesting
class StatusNotifierWatcherEndpoint extends DBusObject {
  StatusNotifierWatcherEndpoint()
    : super(DBusObjectPath(StatusNotifierService.watcherPath));

  Future<void> Function(String address, String? sender)? onRegisterItem;
  Future<void> Function(String host)? onRegisterHost;
  List<String> _registeredItems = const <String>[];
  bool _hostRegistered = false;

  void setRegisteredItems(Iterable<String> registrations) {
    _registeredItems = List<String>.unmodifiable(registrations);
  }

  void setHostRegistered(bool value) {
    _hostRegistered = value;
  }

  Future<void> emitItemRegistered(String address) async {
    for (final interface in <String>[
      StatusNotifierService.watcherInterface,
      StatusNotifierService.standardWatcherInterface,
    ]) {
      await emitSignal(interface, 'StatusNotifierItemRegistered', <DBusValue>[
        DBusString(address),
      ]);
    }
  }

  Future<void> emitItemUnregistered(String address) async {
    for (final interface in <String>[
      StatusNotifierService.watcherInterface,
      StatusNotifierService.standardWatcherInterface,
    ]) {
      await emitSignal(interface, 'StatusNotifierItemUnregistered', <DBusValue>[
        DBusString(address),
      ]);
    }
  }

  Future<void> emitHostRegistered() async {
    for (final interface in <String>[
      StatusNotifierService.watcherInterface,
      StatusNotifierService.standardWatcherInterface,
    ]) {
      await emitSignal(interface, 'StatusNotifierHostRegistered');
    }
  }

  @override
  List<DBusIntrospectInterface> introspect() => <DBusIntrospectInterface>[
    for (final interface in <String>[
      StatusNotifierService.watcherInterface,
      StatusNotifierService.standardWatcherInterface,
    ])
      DBusIntrospectInterface(
        interface,
        methods: <DBusIntrospectMethod>[
          _watcherMethod('RegisterStatusNotifierItem'),
          _watcherMethod('RegisterStatusNotifierHost'),
        ],
        properties: <DBusIntrospectProperty>[
          DBusIntrospectProperty(
            'RegisteredStatusNotifierItems',
            DBusSignature('as'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'IsStatusNotifierHostRegistered',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'ProtocolVersion',
            DBusSignature('i'),
            access: DBusPropertyAccess.read,
          ),
        ],
        signals: <DBusIntrospectSignal>[
          _watcherSignal('StatusNotifierItemRegistered'),
          _watcherSignal('StatusNotifierItemUnregistered'),
          DBusIntrospectSignal('StatusNotifierHostRegistered'),
          DBusIntrospectSignal('StatusNotifierHostUnregistered'),
        ],
      ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != StatusNotifierService.watcherInterface &&
        methodCall.interface !=
            StatusNotifierService.standardWatcherInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (methodCall.signature != DBusSignature('s')) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    switch (methodCall.name) {
      case 'RegisterStatusNotifierItem':
        final callback = onRegisterItem;
        if (callback == null) {
          return DBusMethodErrorResponse.failed('Tray host is unavailable');
        }
        await callback(methodCall.values.first.asString(), methodCall.sender);
        return DBusMethodSuccessResponse();
      case 'RegisterStatusNotifierHost':
        await onRegisterHost?.call(methodCall.values.first.asString());
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != StatusNotifierService.watcherInterface &&
        interface != StatusNotifierService.standardWatcherInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    return switch (name) {
      'RegisteredStatusNotifierItems' => DBusGetPropertyResponse(
        DBusArray.string(_registeredItems),
      ),
      'IsStatusNotifierHostRegistered' => DBusGetPropertyResponse(
        DBusBoolean(_hostRegistered),
      ),
      'ProtocolVersion' => DBusGetPropertyResponse(const DBusInt32(0)),
      _ => DBusMethodErrorResponse.unknownProperty(),
    };
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface != StatusNotifierService.watcherInterface &&
        interface != StatusNotifierService.standardWatcherInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    return DBusGetAllPropertiesResponse(<String, DBusValue>{
      'RegisteredStatusNotifierItems': DBusArray.string(_registeredItems),
      'IsStatusNotifierHostRegistered': DBusBoolean(_hostRegistered),
      'ProtocolVersion': const DBusInt32(0),
    });
  }
}

DBusIntrospectMethod _watcherMethod(String name) => DBusIntrospectMethod(
  name,
  args: <DBusIntrospectArgument>[
    DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_),
  ],
);

DBusIntrospectSignal _watcherSignal(String name) => DBusIntrospectSignal(
  name,
  args: <DBusIntrospectArgument>[
    DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.out),
  ],
);

const Set<String> _knownItemProperties = <String>{
  'Id',
  'Title',
  'Status',
  'IconName',
  'IconPixmap',
  'AttentionIconName',
  'AttentionIconPixmap',
  'IconThemePath',
  'Menu',
  'ItemIsMenu',
};

const Map<String, Set<String>> _itemSignalProperties = <String, Set<String>>{
  'NewTitle': <String>{'Title'},
  'NewStatus': <String>{'Status'},
  'NewIcon': <String>{'IconName', 'IconPixmap'},
  'NewAttentionIcon': <String>{'AttentionIconName', 'AttentionIconPixmap'},
  'NewIconThemePath': <String>{'IconThemePath'},
};

class _PendingStatusNotifierRefresh {
  bool full = false;
  final Set<String> properties = <String>{};
}

class _StatusNotifierRegistration {
  const _StatusNotifierRegistration({
    required this.busName,
    required this.path,
    required this.owner,
  });

  final String busName;
  final String path;
  final String owner;

  String get id => 'status-notifier:$busName:$path';

  String get address => '$busName$path';

  _StatusNotifierRegistration withOwner(String value) =>
      _StatusNotifierRegistration(busName: busName, path: path, owner: value);
}

_StatusNotifierRegistration? _parseRegistration(
  String value, {
  required String? sender,
}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 4096) {
    return null;
  }
  if (trimmed.startsWith('/')) {
    if (sender == null || sender.isEmpty) {
      return null;
    }
    try {
      DBusObjectPath(trimmed);
      return _StatusNotifierRegistration(
        busName: sender,
        path: trimmed,
        owner: sender,
      );
    } on Object {
      return null;
    }
  }
  final slash = trimmed.indexOf('/');
  final busName = slash < 0 ? trimmed : trimmed.substring(0, slash);
  final path = slash < 0 ? '/StatusNotifierItem' : trimmed.substring(slash);
  try {
    if (!_isValidBusName(busName)) {
      return null;
    }
    DBusObjectPath(path);
    return _StatusNotifierRegistration(busName: busName, path: path, owner: '');
  } on Object {
    return null;
  }
}

bool _isValidBusName(String value) {
  if (value.isEmpty || value.length > 255) {
    return false;
  }
  final unique = value.startsWith(':');
  final body = unique ? value.substring(1) : value;
  final parts = body.split('.');
  if (parts.length < 2 || parts.any((part) => part.isEmpty)) {
    return false;
  }
  final segment = unique
      ? RegExp(r'^[A-Za-z0-9_-]+$')
      : RegExp(r'^[A-Za-z_-][A-Za-z0-9_-]*$');
  return parts.every(segment.hasMatch);
}

String _string(DBusValue? value, {String fallback = ''}) {
  try {
    return value?.asString() ?? fallback;
  } on Object {
    return fallback;
  }
}

String? _objectPath(DBusValue? value) {
  try {
    return value?.asObjectPath().value;
  } on Object {
    return null;
  }
}

bool _boolean(DBusValue? value) {
  try {
    return value?.asBoolean() ?? false;
  } on Object {
    return false;
  }
}

String _boundedText(String value, int maxLength) {
  final normalized = value.replaceAll('\u0000', '').trim();
  return normalized.length <= maxLength
      ? normalized
      : normalized.substring(0, maxLength);
}

SystemTrayStatus _status(String value) => switch (value.toLowerCase()) {
  'passive' => SystemTrayStatus.passive,
  'needsattention' => SystemTrayStatus.needsAttention,
  _ => SystemTrayStatus.active,
};

int _statusPriority(SystemTrayStatus status) => switch (status) {
  SystemTrayStatus.needsAttention => 0,
  SystemTrayStatus.active => 1,
  SystemTrayStatus.passive => 2,
};

SystemTrayIconPixmap? _bestPixmap(DBusValue? value) {
  if (value == null || value.signature != DBusSignature('a(iiay)')) {
    return null;
  }
  _StatusNotifierPixmapCandidate? best;
  for (final entry in value.asArray().take(32)) {
    try {
      final tuple = entry.asStruct();
      if (tuple.length != 3 || tuple[2].signature != DBusSignature('ay')) {
        continue;
      }
      final width = tuple[0].asInt32();
      final height = tuple[1].asInt32();
      final byteCount = width * height * 4;
      if (width <= 0 ||
          height <= 0 ||
          width > _StatusNotifierLimits.maxInputDimension ||
          height > _StatusNotifierLimits.maxInputDimension ||
          byteCount > _StatusNotifierLimits.maxInputIconBytes ||
          tuple[2].asArray().length != byteCount) {
        continue;
      }
      final candidate = _StatusNotifierPixmapCandidate(
        width: width,
        height: height,
        bytes: tuple[2].asArray(),
      );
      if (best == null || candidate.score < best.score) {
        best = candidate;
      }
    } on Object {
      continue;
    }
  }
  return best?.decode();
}

class _StatusNotifierPixmapCandidate {
  const _StatusNotifierPixmapCandidate({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;
  final List<DBusValue> bytes;

  int get score {
    final extent = width > height ? width : height;
    final delta = extent - _StatusNotifierLimits.preferredIconDimension;
    return delta >= 0
        ? delta
        : -delta + _StatusNotifierLimits.maxInputDimension;
  }

  SystemTrayIconPixmap decode() {
    final longest = width > height ? width : height;
    final outputScale = longest <= _StatusNotifierLimits.maxOutputDimension
        ? 1.0
        : _StatusNotifierLimits.maxOutputDimension / longest;
    final outputWidth = (width * outputScale).round().clamp(
      1,
      _StatusNotifierLimits.maxOutputDimension,
    );
    final outputHeight = (height * outputScale).round().clamp(
      1,
      _StatusNotifierLimits.maxOutputDimension,
    );
    final rgba = Uint8List(outputWidth * outputHeight * 4);
    for (var outputY = 0; outputY < outputHeight; outputY += 1) {
      final sourceY = outputY * height ~/ outputHeight;
      for (var outputX = 0; outputX < outputWidth; outputX += 1) {
        final sourceX = outputX * width ~/ outputWidth;
        final sourceOffset = (sourceY * width + sourceX) * 4;
        final outputOffset = (outputY * outputWidth + outputX) * 4;
        final alpha = bytes[sourceOffset].asByte();
        rgba[outputOffset] = _premultiplyChannel(
          bytes[sourceOffset + 1].asByte(),
          alpha,
        );
        rgba[outputOffset + 1] = _premultiplyChannel(
          bytes[sourceOffset + 2].asByte(),
          alpha,
        );
        rgba[outputOffset + 2] = _premultiplyChannel(
          bytes[sourceOffset + 3].asByte(),
          alpha,
        );
        rgba[outputOffset + 3] = alpha;
      }
    }
    return SystemTrayIconPixmap(
      width: outputWidth,
      height: outputHeight,
      rgba: rgba,
    );
  }
}

int _premultiplyChannel(int channel, int alpha) {
  return (channel * alpha + 127) ~/ 255;
}

class _MenuBudget {
  _MenuBudget(this.remaining);

  int remaining;
}

SystemTrayMenuEntry? _parseMenuEntry(
  DBusValue value, {
  required _MenuBudget budget,
  required int depth,
}) {
  if (budget.remaining <= 0 ||
      depth > _StatusNotifierDbusBackend._maxMenuDepth) {
    return null;
  }
  try {
    final fields = value.asStruct();
    if (fields.length != 3) {
      return null;
    }
    final id = fields[0].asInt32();
    final properties = fields[1].asStringVariantDict();
    final children = <SystemTrayMenuEntry>[];
    if (depth < _StatusNotifierDbusBackend._maxMenuDepth) {
      for (final child in fields[2].asArray()) {
        if (budget.remaining <= 0) {
          break;
        }
        final parsed = _parseMenuEntry(
          child.asVariant(),
          budget: budget,
          depth: depth + 1,
        );
        if (parsed != null) {
          children.add(parsed);
        }
      }
    }
    budget.remaining -= 1;
    final type = _string(properties['type']);
    final toggleType = switch (_string(properties['toggle-type'])) {
      'checkmark' => SystemTrayMenuToggleType.checkmark,
      'radio' => SystemTrayMenuToggleType.radio,
      _ => SystemTrayMenuToggleType.none,
    };
    return SystemTrayMenuEntry(
      id: id,
      label: _menuLabel(_boundedText(_string(properties['label']), 512)),
      enabled: properties.containsKey('enabled')
          ? _boolean(properties['enabled'])
          : true,
      visible: properties.containsKey('visible')
          ? _boolean(properties['visible'])
          : true,
      separator: type == 'separator',
      toggleType: toggleType,
      toggleState: _int32(properties['toggle-state']),
      destructive: _string(properties['disposition']) == 'warning',
      children: List<SystemTrayMenuEntry>.unmodifiable(children),
    );
  } on Object {
    return null;
  }
}

int _int32(DBusValue? value) {
  try {
    return value?.asInt32() ?? 0;
  } on Object {
    return 0;
  }
}

String _menuLabel(String value) {
  final output = StringBuffer();
  for (var index = 0; index < value.length; index += 1) {
    final character = value[index];
    if (character != '_') {
      output.write(character);
      continue;
    }
    if (index + 1 < value.length && value[index + 1] == '_') {
      output.write('_');
      index += 1;
    }
  }
  return output.toString();
}

abstract final class _StatusNotifierLimits {
  static const int preferredIconDimension = 24;
  static const int maxInputDimension = 512;
  static const int maxInputIconBytes =
      maxInputDimension * maxInputDimension * 4;
  static const int maxOutputDimension = 64;
}

@visibleForTesting
SystemTrayIconPixmap? decodeStatusNotifierPixmapForTesting(DBusValue value) =>
    _bestPixmap(value);

@visibleForTesting
Set<String> statusNotifierPropertiesForSignalForTesting(String signal) =>
    Set<String>.unmodifiable(_itemSignalProperties[signal] ?? const <String>{});
