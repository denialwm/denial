import 'package:test/test.dart';

import 'package:denial_flutter_sdk/src/services/mobile_network_snapshot.dart';

MobileNetworkSnapshot snapshot({
  MobileSimPresence presence = MobileSimPresence.present,
  String path = '/modem/0',
  bool connected = false,
  bool registered = false,
  bool manager = true,
  bool enabled = true,
  bool hardware = true,
  int lock = 1,
}) => MobileNetworkSnapshot(
  modemPath: path,
  simPresence: presence,
  connected: connected,
  registered: registered,
  managerAvailable: manager,
  enabled: enabled,
  hardwareEnabled: hardware,
  unlockRequired: lock,
);

void main() {
  MobileSimPresence presence({
    String? sim = '/',
    List<String>? slots,
    int lock = 1,
    int state = 3,
    int failure = 0,
    MobileSimPresence previous = MobileSimPresence.unknown,
  }) => mobileSimPresence(
    simPath: sim,
    simSlots: slots,
    unlockRequired: lock,
    state: state,
    failedReason: failure,
    previous: previous,
  );

  test(
    'loading/default and discovery failure are unknown, visible unavailable',
    () {
      const initial = MobileNetworkSnapshot();
      expect(initial.simPresence, MobileSimPresence.unknown);
      expect(initial.showCellular, isTrue);
      expect(initial.cellularWorking, isFalse);
      expect(initial.unavailable().simPresence, MobileSimPresence.unknown);
      expect(presence(sim: null, state: 0, lock: 0), MobileSimPresence.unknown);
      expect(presence(), MobileSimPresence.unknown);
      expect(presence(slots: []), MobileSimPresence.unknown);
    },
  );

  test(
    'confirmed absent hides only with explicit missing/settled slot evidence',
    () {
      expect(presence(slots: ['/', '/']), MobileSimPresence.absent);
      expect(presence(state: -1, failure: 2), MobileSimPresence.absent);
      final absent = snapshot(presence: MobileSimPresence.absent);
      expect(absent.showCellular, isFalse);
      expect(absent.cellularWorking, isFalse);
      // An outage is no longer a current absence report.
      expect(absent.unavailable().showCellular, isTrue);
    },
  );

  test('initializing empty slots cannot erase a known SIM', () {
    expect(presence(slots: ['/'], state: 1), MobileSimPresence.unknown);
    expect(presence(slots: ['/'], state: 0), MobileSimPresence.unknown);
    expect(
      presence(slots: ['/'], state: 1, previous: MobileSimPresence.present),
      MobileSimPresence.present,
    );
  });

  test(
    'active or inactive slot is presence, including primary slot missing',
    () {
      expect(presence(sim: '/sim/0'), MobileSimPresence.present);
      expect(presence(slots: ['/', '/sim/1']), MobileSimPresence.present);
      expect(
        presence(slots: ['/', '/sim/1'], state: -1, failure: 2),
        MobileSimPresence.present,
      );
    },
  );

  test('PIN/PUK locked SIM stays present without an accessible SIM object', () {
    for (final lock in [2, 3, 4, 5]) {
      expect(
        presence(sim: null, slots: ['/'], lock: lock, state: 2),
        MobileSimPresence.present,
      );
    }
    for (final lock in [2, 4, 6, 8, 10]) {
      final locked = snapshot(lock: lock, connected: true, registered: true);
      expect(locked.showCellular, isTrue);
      expect(locked.cellularWorking, isFalse);
    }
  });

  test(
    'SIM_ERROR means present unusable; unrelated failures are not absence',
    () {
      expect(presence(state: -1, failure: 3), MobileSimPresence.present);
      for (final failure in [0, 1, 4, 5]) {
        expect(
          presence(state: -1, failure: failure),
          MobileSimPresence.unknown,
        );
      }
    },
  );

  test('disconnected, registered-only, disabled or unavailable use !', () {
    for (final value in [
      snapshot(),
      snapshot(registered: true),
      snapshot(connected: true),
      snapshot(connected: true, registered: true, manager: false),
      snapshot(connected: true, registered: true, enabled: false),
      snapshot(connected: true, registered: true, hardware: false),
      snapshot(
        presence: MobileSimPresence.unknown,
        connected: true,
        registered: true,
      ),
    ]) {
      expect(value.showCellular, isTrue);
      expect(value.cellularWorking, isFalse);
    }
  });

  test('normal icon requires reported cellular connection, not Wi-Fi', () {
    expect(snapshot(connected: true, registered: true).cellularWorking, isTrue);
    // PIN2 and PUK2 protect supplementary functions, not the connection.
    for (final lock in [3, 5]) {
      expect(
        snapshot(connected: true, registered: true, lock: lock).cellularWorking,
        isTrue,
      );
    }
  });

  test(
    'service loss/reprobe retains presence, disables actions, then recovers',
    () {
      final working = snapshot(connected: true, registered: true);
      final lost = working.unavailable();
      expect(lost.simPresence, MobileSimPresence.present);
      expect(lost.showCellular, isTrue);
      expect(lost.cellularWorking, isFalse);
      expect(lost.canToggle, isFalse);
      expect(lost.pinRequired, isFalse);
      expect(lost.simPath, isNull);
      expect(lost.modemPath, working.modemPath);
      expect(
        selectMobileNetworkSnapshot([], previous: lost).simPresence,
        MobileSimPresence.present,
      );
      expect(
        presence(state: 1, previous: lost.simPresence),
        MobileSimPresence.present,
      );
      final recovered = selectMobileNetworkSnapshot([working], previous: lost);
      expect(recovered.cellularWorking, isTrue);
      final removed = snapshot(presence: presence(slots: ['/']));
      expect(
        selectMobileNetworkSnapshot([
          removed,
        ], previous: recovered).showCellular,
        isFalse,
      );
    },
  );

  test(
    'multi-modem status prefers present SIM then locked SIM; stable ordering',
    () {
      const previous = MobileNetworkSnapshot();
      final absent = snapshot(
        path: '/modem/0',
        presence: MobileSimPresence.absent,
      );
      final unknown = snapshot(
        path: '/modem/1',
        presence: MobileSimPresence.unknown,
      );
      final working = snapshot(
        path: '/modem/2',
        connected: true,
        registered: true,
      );
      final locked = snapshot(path: '/modem/3', lock: 2);
      expect(
        selectMobileNetworkSnapshot([absent, unknown], previous: previous),
        unknown,
      );
      expect(
        selectMobileNetworkSnapshot([
          absent,
          unknown,
          working,
        ], previous: previous),
        working,
      );
      expect(
        selectMobileNetworkSnapshot([working, locked], previous: previous),
        locked,
      );
      final same = snapshot(path: '/modem/4', lock: 2);
      expect(
        selectMobileNetworkSnapshot([same, locked], previous: previous),
        locked,
      );
      expect(
        selectMobileNetworkSnapshot([
          absent,
        ], previous: snapshot()).showCellular,
        isFalse,
      );
    },
  );
  test('a disappearing modem is not removal evidence from another modem', () {
    final working = snapshot(
      path: '/modem/0',
      connected: true,
      registered: true,
    );
    final otherEmpty = snapshot(
      path: '/modem/1',
      presence: MobileSimPresence.absent,
    );
    final reprobe = selectMobileNetworkSnapshot([
      otherEmpty,
    ], previous: working);
    expect(reprobe.simPresence, MobileSimPresence.present);
    expect(reprobe.cellularWorking, isFalse);
    final replacement = snapshot(
      path: '/modem/2',
      connected: true,
      registered: true,
    );
    expect(
      selectMobileNetworkSnapshot([otherEmpty, replacement], previous: reprobe),
      replacement,
    );
  });
}
