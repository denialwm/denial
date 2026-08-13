import 'dart:io';

import 'package:denial_dart_shell/src/models/battery_status.dart';
import 'package:denial_dart_shell/src/services/battery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('denial-batteries-');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> addBattery(
    String name, {
    required int capacity,
    String status = 'Discharging',
    int? chargeFull,
    int? energyFull,
    int present = 1,
  }) async {
    final battery = await Directory('${root.path}/$name').create();
    final fields = <String, Object>{
      'type': 'Battery',
      'present': present,
      'capacity': capacity,
      'status': status,
      'charge_full': ?chargeFull,
      'energy_full': ?energyFull,
    };
    for (final entry in fields.entries) {
      await File(
        '${battery.path}/${entry.key}',
      ).writeAsString('${entry.value}\n');
    }
  }

  test(
    'ignores incomplete firmware placeholders beside a measurable battery',
    () async {
      await addBattery('real-gauge', capacity: 47, chargeFull: 2496000);
      await addBattery('firmware-placeholder', capacity: 50);

      expect(
        await BatteryService(powerSupplyRoot: root.path).read(),
        const BatteryStatus(capacity: 47, charging: false),
      );
    },
  );

  test(
    'aggregates multiple measurable laptop batteries by full capacity',
    () async {
      await addBattery('BAT0', capacity: 25, energyFull: 1000);
      await addBattery(
        'BAT1',
        capacity: 75,
        energyFull: 3000,
        status: 'Charging',
      );

      expect(
        await BatteryService(powerSupplyRoot: root.path).read(),
        const BatteryStatus(capacity: 63, charging: true),
      );
    },
  );

  test('falls back to averaging valid capacity-only batteries', () async {
    await addBattery('BAT0', capacity: 40);
    await addBattery('BAT1', capacity: 60);
    await addBattery('absent', capacity: 99, present: 0);

    expect(
      await BatteryService(powerSupplyRoot: root.path).read(),
      const BatteryStatus(capacity: 50, charging: false),
    );
  });

  test('does not combine energy and charge units as weights', () async {
    await addBattery('energy', capacity: 25, energyFull: 9000);
    await addBattery('charge', capacity: 75, chargeFull: 1000);

    expect(
      await BatteryService(powerSupplyRoot: root.path).read(),
      const BatteryStatus(capacity: 50, charging: false),
    );
  });
}
