part of 'status_notifier_service.dart';

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
