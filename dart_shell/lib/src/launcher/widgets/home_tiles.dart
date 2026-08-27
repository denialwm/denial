import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_icon.dart';
import '../controllers/home_grid_controller.dart';
import '../models/home_battery_discharge_info.dart';
import '../models/home_clock_info.dart';
import '../models/home_grid_item.dart';

part 'home_app_tile.dart';
part 'home_battery_tile.dart';
part 'home_clock_tile.dart';

class HomeGridItemCard extends ConsumerWidget {
  const HomeGridItemCard({
    super.key,
    required this.item,
    this.launchEnabled = true,
    required this.onLaunch,
  });

  final HomeGridItem item;
  final bool launchEnabled;
  final ValueChanged<HomeGridItem> onLaunch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (item.type) {
      HomeGridItemType.clock => HomeClockWidget(
        clock: ref.watch(homeClockProvider),
      ),
      HomeGridItemType.batteryDischarge => _HomeBatteryDischargeTile(
        series:
            ref.watch(homeBatteryDischargeProvider).asData?.value ??
            HomeBatteryDischargeSeries.empty,
      ),
      HomeGridItemType.app => _HomeAppTile(
        name: item.localApp?.titleFor(context) ?? item.app!.name,
        iconPath: item.app?.iconPath,
        icon: item.localApp?.icon,
        onTap: launchEnabled ? () => onLaunch(item) : null,
      ),
    };
  }
}

/// The centered clock, date, and power summary used by the Home grid.
///
/// Other shell surfaces should reuse this widget when they need the same
/// presentation rather than maintaining a visually divergent copy.
