import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/status_notifier_service.dart';
import 'package:denial_dart_shell/src/models/system_tray_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production service keeps D-Bus off the UI isolate', () async {
    final service = StatusNotifierService();
    addTearDown(service.dispose);

    expect(service.isolatesDbus, isTrue);
  });

  test('item signals request only the properties they invalidate', () {
    expect(statusNotifierPropertiesForSignalForTesting('NewTitle'), <String>{
      'Title',
    });
    expect(statusNotifierPropertiesForSignalForTesting('NewIcon'), <String>{
      'IconName',
      'IconPixmap',
    });
    expect(
      statusNotifierPropertiesForSignalForTesting('UnknownSignal'),
      isEmpty,
    );
  });

  test('large icon pixmaps are decoded into bounded premultiplied RGBA', () {
    const width = 128;
    const height = 64;
    final argb = <int>[
      for (var pixel = 0; pixel < width * height; pixel += 1) ...const <int>[
        0x7f,
        0x11,
        0x22,
        0x33,
      ],
    ];
    final value = DBusArray(DBusSignature('(iiay)'), <DBusValue>[
      DBusStruct(<DBusValue>[
        const DBusInt32(width),
        const DBusInt32(height),
        DBusArray.byte(argb),
      ]),
    ]);

    final pixmap = decodeStatusNotifierPixmapForTesting(value);

    expect(pixmap, isNotNull);
    expect(pixmap!.width, 64);
    expect(pixmap.height, 32);
    expect(pixmap.rgba, hasLength(64 * 32 * 4));
    expect(pixmap.rgba.sublist(0, 4), <int>[0x08, 0x11, 0x19, 0x7f]);
  });

  test('watcher endpoint registers items with sender identity', () async {
    final endpoint = StatusNotifierWatcherEndpoint();
    String? registeredAddress;
    String? registeredSender;
    endpoint.onRegisterItem = (address, sender) async {
      registeredAddress = address;
      registeredSender = sender;
    };

    final response = await endpoint.handleMethodCall(
      const DBusMethodCall(
        sender: ':1.42',
        interface: StatusNotifierService.watcherInterface,
        name: 'RegisterStatusNotifierItem',
        values: <DBusValue>[DBusString('/StatusNotifierItem')],
      ),
    );

    expect(response, isA<DBusMethodSuccessResponse>());
    expect(registeredAddress, '/StatusNotifierItem');
    expect(registeredSender, ':1.42');
  });

  test('watcher endpoint publishes protocol properties', () async {
    final endpoint = StatusNotifierWatcherEndpoint()
      ..setRegisteredItems(<String>[
        'org.example.One/StatusNotifierItem',
        ':1.8/StatusNotifierItem',
      ])
      ..setHostRegistered(true);

    final response = await endpoint.getAllProperties(
      StatusNotifierService.watcherInterface,
    );
    final values = response.returnValues.single.asStringVariantDict();

    expect(values['RegisteredStatusNotifierItems']!.asStringArray(), <String>[
      'org.example.One/StatusNotifierItem',
      ':1.8/StatusNotifierItem',
    ]);
    expect(values['IsStatusNotifierHostRegistered']!.asBoolean(), isTrue);
    expect(values['ProtocolVersion']!.asInt32(), 0);
    expect(
      endpoint.introspect().map((interface) => interface.name),
      containsAll(<String>[
        StatusNotifierService.watcherInterface,
        StatusNotifierService.standardWatcherInterface,
      ]),
    );
  });

  test('watcher endpoint rejects malformed registration calls', () async {
    final endpoint = StatusNotifierWatcherEndpoint();
    final response = await endpoint.handleMethodCall(
      const DBusMethodCall(
        sender: ':1.42',
        interface: StatusNotifierService.watcherInterface,
        name: 'RegisterStatusNotifierItem',
        values: <DBusValue>[DBusUint32(7)],
      ),
    );

    expect(response, isA<DBusMethodErrorResponse>());
  });

  test('session-bus watcher discovers items and forwards actions', () async {
    if (Platform.environment['DENIAL_STATUS_NOTIFIER_TEST_BUS'] != '1') {
      return;
    }
    final service = StatusNotifierService();
    final itemClient = DBusClient.session();
    final item = _TestStatusNotifierItem();
    final menu = _TestDbusMenu();
    try {
      await service.start();
      await itemClient.requestName(
        'org.example.DenialStatusNotifierTest',
        flags: const <DBusRequestNameFlag>{DBusRequestNameFlag.doNotQueue},
      );
      await itemClient.registerObject(item);
      await itemClient.registerObject(menu);
      final snapshot = service.snapshots.firstWhere(
        (items) => items.isNotEmpty,
      );
      final watcher = DBusRemoteObject(
        itemClient,
        name: StatusNotifierService.watcherName,
        path: DBusObjectPath(StatusNotifierService.watcherPath),
      );
      await watcher.callMethod(
        StatusNotifierService.watcherInterface,
        'RegisterStatusNotifierItem',
        const <DBusValue>[
          DBusString('org.example.DenialStatusNotifierTest/StatusNotifierItem'),
        ],
        replySignature: DBusSignature(''),
      );

      final trayItem = (await snapshot.timeout(
        const Duration(seconds: 3),
      )).single;
      expect(trayItem.title, 'Test indicator');
      expect(trayItem.iconName, 'test-indicator-attention');
      expect(trayItem.status, SystemTrayStatus.needsAttention);
      expect(trayItem.menuAvailable, isTrue);
      expect(trayItem.primaryOpensMenu, isTrue);
      expect(trayItem.menuPath, '/Menu');
      expect(item.getAllCalls, 1);

      final changedSnapshot = service.snapshots.firstWhere(
        (items) => items.singleOrNull?.title == 'Renamed indicator',
      );
      await item.changeTitle('Renamed indicator');
      expect(
        (await changedSnapshot.timeout(
          const Duration(seconds: 3),
        )).single.title,
        'Renamed indicator',
      );
      expect(item.propertyReads, <String>['Title']);
      expect(item.getAllCalls, 1);

      // The former implementation fetched every property every five seconds.
      // Waiting across that boundary proves updates are now signal-driven.
      await Future<void>.delayed(const Duration(milliseconds: 5200));
      expect(item.getAllCalls, 1);

      for (final action in SystemTrayAction.values) {
        expect(
          await service.invoke(trayItem, action, const Offset(120, 40)),
          isTrue,
        );
      }
      expect(item.methods, <String>[
        'Activate',
        'SecondaryActivate',
        'ContextMenu',
      ]);

      final entries = await service.loadMenu(trayItem);
      expect(entries, hasLength(3));
      expect(entries![0].label, 'Open Steam');
      expect(entries[0].enabled, isTrue);
      expect(entries[1].separator, isTrue);
      expect(entries[2].label, 'Run at startup');
      expect(entries[2].toggleType, SystemTrayMenuToggleType.checkmark);
      expect(entries[2].toggleState, 1);
      expect(menu.aboutToShowIds, <int>[0]);

      expect(await service.activateMenuEntry(trayItem, 43), isTrue);
      expect(menu.clickedIds, <int>[43]);

      final standardWatcher = DBusRemoteObject(
        itemClient,
        name: StatusNotifierService.standardWatcherName,
        path: DBusObjectPath(StatusNotifierService.watcherPath),
      );
      final registered = await standardWatcher.getProperty(
        StatusNotifierService.standardWatcherInterface,
        'RegisteredStatusNotifierItems',
        signature: DBusSignature('as'),
      );
      expect(
        registered.asStringArray(),
        contains('org.example.DenialStatusNotifierTest/StatusNotifierItem'),
      );
    } finally {
      await itemClient.unregisterObject(menu);
      await itemClient.unregisterObject(item);
      await itemClient.close();
      await service.dispose();
    }
  });
}

class _TestDbusMenu extends DBusObject {
  _TestDbusMenu() : super(DBusObjectPath('/Menu'));

  final List<int> aboutToShowIds = <int>[];
  final List<int> clickedIds = <int>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != StatusNotifierService.menuInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'AboutToShow':
        aboutToShowIds.add(methodCall.values.single.asInt32());
        return DBusMethodSuccessResponse(const <DBusValue>[DBusBoolean(false)]);
      case 'GetLayout':
        return DBusMethodSuccessResponse(<DBusValue>[
          const DBusUint32(7),
          _menuNode(0, const <String, DBusValue>{}, <DBusValue>[
            _menuNode(28, const <String, DBusValue>{
              'label': DBusString('_Open Steam'),
            }),
            _menuNode(30, const <String, DBusValue>{
              'type': DBusString('separator'),
            }),
            _menuNode(41, const <String, DBusValue>{
              'label': DBusString('Run at startup'),
              'toggle-type': DBusString('checkmark'),
              'toggle-state': DBusInt32(1),
            }),
          ]),
        ]);
      case 'Event':
        clickedIds.add(methodCall.values.first.asInt32());
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

DBusStruct _menuNode(
  int id,
  Map<String, DBusValue> properties, [
  List<DBusValue> children = const <DBusValue>[],
]) {
  return DBusStruct(<DBusValue>[
    DBusInt32(id),
    DBusDict.stringVariant(properties),
    DBusArray.variant(children),
  ]);
}

class _TestStatusNotifierItem extends DBusObject {
  _TestStatusNotifierItem() : super(DBusObjectPath('/StatusNotifierItem'));

  final List<String> methods = <String>[];
  final List<String> propertyReads = <String>[];
  int getAllCalls = 0;
  String title = 'Test indicator';

  Map<String, DBusValue> get _properties => <String, DBusValue>{
    'Id': const DBusString('test-indicator'),
    'Title': DBusString(title),
    'Status': const DBusString('NeedsAttention'),
    'IconName': const DBusString('test-indicator'),
    'AttentionIconName': const DBusString('test-indicator-attention'),
    'Menu': DBusObjectPath('/Menu'),
    'ItemIsMenu': const DBusBoolean(true),
  };

  Future<void> changeTitle(String value) async {
    title = value;
    await emitSignal(StatusNotifierService.itemInterface, 'NewTitle');
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != StatusNotifierService.itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    if (value == null) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    propertyReads.add(name);
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface != StatusNotifierService.itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    getAllCalls += 1;
    return DBusGetAllPropertiesResponse(_properties);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != StatusNotifierService.itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (!const <String>{
      'Activate',
      'SecondaryActivate',
      'ContextMenu',
    }.contains(methodCall.name)) {
      return DBusMethodErrorResponse.unknownMethod();
    }
    methods.add(methodCall.name);
    return DBusMethodSuccessResponse();
  }
}
