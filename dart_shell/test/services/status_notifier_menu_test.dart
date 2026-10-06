import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/models/system_tray_item.dart';
import 'package:denial_dart_shell/src/services/status_notifier_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('menu layout requests exactly one level for the requested parent', () {
    final request = statusNotifierMenuLayoutRequestForTesting(73);

    expect(request[0].asInt32(), 73);
    expect(request[1].asInt32(), 1);
    expect(
      request[2].asStringArray(),
      containsAll(<String>['label', 'visible', 'children-display']),
    );
  });

  test('a large early subtree cannot hide later siblings', () {
    final layout = _menuNode(0, const <String, DBusValue>{}, <DBusValue>[
      _menuNode(
        1,
        const <String, DBusValue>{
          'label': DBusString('Large submenu'),
          'children-display': DBusString('submenu'),
        },
        <DBusValue>[
          for (var index = 0; index < 300; index += 1)
            _menuNode(1000 + index, <String, DBusValue>{
              'label': DBusString('Nested $index'),
            }),
        ],
      ),
      _menuNode(2, const <String, DBusValue>{
        'label': DBusString('Later sibling'),
      }),
    ]);

    final entries = parseStatusNotifierMenuForTesting(layout);

    expect(entries, hasLength(2));
    expect(entries![0].label, 'Large submenu');
    expect(entries[0].hasSubmenu, isTrue);
    expect(entries[0].children, isEmpty);
    expect(entries[1].label, 'Later sibling');
  });

  test('per-level menu overflow is explicit and bounded', () {
    final layout = _menuNode(0, const <String, DBusValue>{}, <DBusValue>[
      for (var index = 0; index < 2050; index += 1)
        _menuNode(index + 1, <String, DBusValue>{
          'label': DBusString('Item $index'),
        }),
    ]);

    final entries = parseStatusNotifierMenuForTesting(layout);

    expect(entries, hasLength(2049));
    expect(entries!.last.id, 0);
    expect(entries.last.enabled, isFalse);
    expect(entries.last.label, 'Additional menu items omitted');
  });

  test('submenu metadata survives the worker isolate value boundary', () {
    const source = <SystemTrayMenuEntry>[
      SystemTrayMenuEntry(
        id: 17,
        label: 'Proxy',
        enabled: true,
        visible: true,
        separator: false,
        toggleType: SystemTrayMenuToggleType.none,
        toggleState: 0,
        destructive: false,
        hasSubmenu: true,
        children: <SystemTrayMenuEntry>[],
      ),
    ];

    final encoded = encodeStatusNotifierMenuEntriesForTesting(source);
    final decoded = decodeStatusNotifierMenuEntriesForTesting(encoded);

    expect(decoded, hasLength(1));
    expect(decoded!.single.id, 17);
    expect(decoded.single.hasSubmenu, isTrue);
    expect(decoded.single.children, isEmpty);
  });
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
