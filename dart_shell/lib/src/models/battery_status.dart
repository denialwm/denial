import 'package:flutter/foundation.dart';

/// Immutable snapshot of the device battery.
@immutable
class BatteryStatus {
  const BatteryStatus({required this.capacity, required this.charging});

  static const BatteryStatus unknown =
      BatteryStatus(capacity: null, charging: false);

  /// Percentage in `[0, 100]`, or null when unavailable.
  final int? capacity;
  final bool charging;

  String get label {
    final percent = capacity == null ? '--' : '$capacity%';
    return charging ? '$percent in carica' : percent;
  }

  @override
  bool operator ==(Object other) =>
      other is BatteryStatus &&
      other.capacity == capacity &&
      other.charging == charging;

  @override
  int get hashCode => Object.hash(capacity, charging);
}
