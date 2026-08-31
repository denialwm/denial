import 'package:flutter/foundation.dart';

import '../models/battery_status.dart';
import '../services/battery_notification_service.dart';

@immutable
class LowBatteryWarning {
  const LowBatteryWarning({required this.threshold, required this.capacity});

  final int threshold;
  final int capacity;

  bool get critical => threshold <= 10;
}

/// Selects each progressively lower warning once per discharge cycle.
///
/// Polling may skip an exact percentage, so a reading of 14% selects the 15%
/// warning. Higher, already-crossed thresholds are consumed at the same time
/// to prevent stale warnings from appearing later. Charging above a threshold
/// rearms it for the next discharge.
class LowBatteryWarningTracker {
  static const List<int> thresholds = <int>[20, 15, 10, 5, 1];

  final Set<int> _consumed = <int>{};

  LowBatteryWarning? update(BatteryStatus status) {
    final capacity = status.capacity;
    if (capacity == null) {
      return null;
    }

    _consumed.removeWhere((threshold) => capacity > threshold);
    if (status.charging || capacity > thresholds.first) {
      return null;
    }

    final threshold = thresholds.reversed.firstWhere(
      (candidate) => capacity <= candidate,
    );
    if (_consumed.contains(threshold)) {
      return null;
    }
    _consumed.addAll(thresholds.where((candidate) => candidate >= threshold));
    return LowBatteryWarning(threshold: threshold, capacity: capacity);
  }
}

class LowBatteryNotificationCopy {
  const LowBatteryNotificationCopy({
    required this.lowTitle,
    required this.criticalTitle,
    required this.body,
  });

  final String lowTitle;
  final String criticalTitle;
  final String Function(int capacity) body;
}

class LowBatteryNotificationCoordinator {
  LowBatteryNotificationCoordinator(
    this._sink, {
    LowBatteryWarningTracker? tracker,
  }) : _tracker = tracker ?? LowBatteryWarningTracker();

  final BatteryNotificationSink _sink;
  final LowBatteryWarningTracker _tracker;

  Future<void> update(
    BatteryStatus status, {
    required LowBatteryNotificationCopy copy,
  }) {
    final warning = _tracker.update(status);
    if (warning != null) {
      return _sink.show(
        BatteryNotification(
          threshold: warning.threshold,
          capacity: warning.capacity,
          summary: warning.critical ? copy.criticalTitle : copy.lowTitle,
          body: copy.body(warning.capacity),
          critical: warning.critical,
        ),
      );
    }

    final capacity = status.capacity;
    if (status.charging || (capacity != null && capacity > 20)) {
      return _sink.dismiss();
    }
    return Future<void>.value();
  }
}
