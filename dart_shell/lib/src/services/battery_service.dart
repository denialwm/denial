import 'dart:io';

import '../models/battery_status.dart';
import 'system_io.dart';

/// Reads and aggregates standard Linux battery power supplies from sysfs.
class BatteryService {
  const BatteryService({this.powerSupplyRoot = '/sys/class/power_supply'});

  final String powerSupplyRoot;

  Future<BatteryStatus> read() async {
    final scan = await _readSamples();
    final samples = scan.samples;
    if (samples.isEmpty) {
      return BatteryStatus.unknown;
    }

    // A real system battery normally publishes its full charge or energy.
    // If any such supplies exist, exclude incomplete firmware placeholders
    // rather than letting a made-up percentage distort the aggregate.
    final measurable = samples
        .where((sample) => sample.weight != null && sample.weightKind != null)
        .toList();
    final selected = measurable.isEmpty ? samples : measurable;
    final weightKinds = selected
        .map((sample) => sample.weightKind)
        .whereType<_BatteryWeightKind>()
        .toSet();
    // energy_full is measured in micro-watt-hours, while charge_full is
    // measured in micro-amp-hours. They are valid relative weights only
    // within their own dimension. If drivers expose a mixed set, retain all
    // measurable batteries and use an unweighted average rather than
    // combining incompatible units.
    final weighted = weightKinds.length == 1;
    final capacity = weighted
        ? (selected.fold<double>(
                    0,
                    (sum, sample) => sum + sample.capacity * sample.weight!,
                  ) /
                  selected.fold<double>(
                    0,
                    (sum, sample) => sum + sample.weight!,
                  ))
              .round()
        : (selected.fold<int>(0, (sum, sample) => sum + sample.capacity) /
                  selected.length)
              .round();
    return BatteryStatus(
      capacity: capacity.clamp(0, 100),
      charging: selected.any((sample) => sample.charging),
    );
  }

  Future<_BatteryScan> _readSamples() async {
    try {
      final samples = <_BatterySample>[];
      await for (final entity in Directory(powerSupplyRoot).list()) {
        if (entity is! Directory && entity is! Link) {
          continue;
        }
        final path = entity.path;
        if ((await readSysString('$path/type'))?.toLowerCase() != 'battery') {
          continue;
        }
        final present = await readSysInt('$path/present');
        if (present == 0) {
          continue;
        }
        final capacity = await readSysInt('$path/capacity');
        if (capacity == null || capacity < 0 || capacity > 100) {
          continue;
        }
        final energyFull = await readSysInt('$path/energy_full');
        final chargeFull = await readSysInt('$path/charge_full');
        final weight = switch ((energyFull, chargeFull)) {
          (final value?, _) when value > 0 => value.toDouble(),
          (_, final value?) when value > 0 => value.toDouble(),
          _ => null,
        };
        final weightKind = switch ((energyFull, chargeFull)) {
          (final value?, _) when value > 0 => _BatteryWeightKind.energy,
          (_, final value?) when value > 0 => _BatteryWeightKind.charge,
          _ => null,
        };
        final status = (await readSysString('$path/status'))?.toLowerCase();
        samples.add(
          _BatterySample(
            capacity: capacity,
            charging: status == 'charging',
            weight: weight,
            weightKind: weightKind,
          ),
        );
      }
      return _BatteryScan(samples: samples);
    } on FileSystemException {
      return const _BatteryScan(samples: <_BatterySample>[]);
    }
  }
}

class _BatteryScan {
  const _BatteryScan({required this.samples});

  final List<_BatterySample> samples;
}

enum _BatteryWeightKind { energy, charge }

class _BatterySample {
  const _BatterySample({
    required this.capacity,
    required this.charging,
    required this.weight,
    required this.weightKind,
  });

  final int capacity;
  final bool charging;
  final double? weight;
  final _BatteryWeightKind? weightKind;
}
