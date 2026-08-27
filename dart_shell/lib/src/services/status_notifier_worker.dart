part of 'status_notifier_service.dart';

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
