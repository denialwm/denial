import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_icon.dart';
import '../controllers/home_grid_controller.dart';
import '../models/home_clock_info.dart';
import '../models/home_grid_item.dart';

part 'home_app_tile.dart';
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
  final void Function(HomeGridItem item, Rect sourceRect) onLaunch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (item.type) {
      HomeGridItemType.clock => HomeClockWidget(
        clock: ref.watch(homeClockProvider),
      ),
      HomeGridItemType.app => _HomeAppTile(
        name: item.localApp?.titleFor(context) ?? item.app!.name,
        iconPath: item.app?.iconPath,
        icon: item.localApp?.icon,
        onTap: launchEnabled ? (rect) => onLaunch(item, rect) : null,
      ),
    };
  }
}
