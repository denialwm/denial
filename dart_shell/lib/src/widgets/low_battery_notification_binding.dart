import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/denial_localizations.dart';
import '../models/battery_status.dart';
import '../services/battery_notification_service.dart';
import '../state/low_battery_notifications.dart';
import '../state/system_status.dart';

/// Keeps low-battery alerts active for the lifetime of the shell scene.
class LowBatteryNotificationBinding extends ConsumerStatefulWidget {
  const LowBatteryNotificationBinding({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LowBatteryNotificationBinding> createState() =>
      _LowBatteryNotificationBindingState();
}

class _LowBatteryNotificationBindingState
    extends ConsumerState<LowBatteryNotificationBinding> {
  late final LowBatteryNotificationCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    _coordinator = LowBatteryNotificationCoordinator(
      ref.read(batteryNotificationSinkProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<BatteryStatus>(batteryProvider, (_, status) {
      final l10n = context.l10n;
      unawaited(
        _reportFailure(
          _coordinator.update(
            status,
            copy: LowBatteryNotificationCopy(
              lowTitle: l10n.batteryLowNotificationTitle,
              criticalTitle: l10n.batteryCriticalNotificationTitle,
              body: l10n.batteryLowNotificationBody,
            ),
          ),
        ),
      );
    });
    return widget.child;
  }

  Future<void> _reportFailure(Future<void> operation) async {
    try {
      await operation;
    } on Object catch (error) {
      debugPrint('Could not publish low-battery notification: $error');
    }
  }
}
