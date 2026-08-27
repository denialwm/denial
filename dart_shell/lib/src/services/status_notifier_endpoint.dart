part of 'status_notifier_service.dart';

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
