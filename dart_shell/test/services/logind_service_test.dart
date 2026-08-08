import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/logind_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logind capability values preserve authorization semantics', () {
    expect(parseLogindCapability('yes'), LogindCapability.available);
    expect(
      parseLogindCapability('challenge'),
      LogindCapability.authenticationRequired,
    );
    expect(parseLogindCapability('no'), LogindCapability.denied);
    expect(parseLogindCapability('na'), LogindCapability.unsupported);
    expect(parseLogindCapability('unexpected'), LogindCapability.unavailable);
  });

  test('inhibitors are parsed, sanitized, classified, and bounded', () {
    final value = DBusArray(DBusSignature('(ssssuu)'), <DBusValue>[
      _inhibitor(
        what: 'sleep:shutdown',
        who: 'Game',
        why: 'Saving\u0000 progress',
        mode: 'block',
      ),
      _inhibitor(
        what: 'sleep',
        who: 'Backup',
        why: 'Finishing archive',
        mode: 'delay',
      ),
      _inhibitor(what: 'sleep', who: 'Broken', why: 'Ignored', mode: 'mystery'),
      for (var index = 0; index < 80; index += 1)
        _inhibitor(
          what: 'shutdown',
          who: 'App $index',
          why: 'Reason $index',
          mode: 'block',
        ),
    ]);

    final inhibitors = parseLogindInhibitors(value, maximum: 8);

    expect(inhibitors, hasLength(8));
    expect(inhibitors.first.what, <String>{'sleep', 'shutdown'});
    expect(inhibitors.first.description, 'Game: Saving progress');
    expect(inhibitors.first.blocks(LogindAction.suspend), isTrue);
    expect(inhibitors.first.blocks(LogindAction.powerOff), isTrue);
    expect(inhibitors[1].delays(LogindAction.hibernate), isTrue);
    expect(
      inhibitors.where((inhibitor) => inhibitor.mode == 'mystery'),
      isEmpty,
    );
  });

  test('malformed inhibitor values fail closed without throwing', () {
    expect(parseLogindInhibitors(const DBusString('wrong type')), isEmpty);
    expect(
      parseLogindInhibitors(
        DBusArray.unchecked(DBusSignature('(ssssuu)'), <DBusValue>[
          DBusStruct(<DBusValue>[
            const DBusString('sleep'),
            const DBusString('missing fields'),
          ]),
        ]),
      ),
      isEmpty,
    );
  });
}

DBusStruct _inhibitor({
  required String what,
  required String who,
  required String why,
  required String mode,
}) {
  return DBusStruct(<DBusValue>[
    DBusString(what),
    DBusString(who),
    DBusString(why),
    DBusString(mode),
    const DBusUint32(1000),
    const DBusUint32(4242),
  ]);
}
