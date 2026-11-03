import 'package:denial_clock_ui/clock_face.dart';
export 'package:denial_clock_ui/clock_face.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';

import 'home_app_tile.dart';

/// Any home item at its tile's size.
class HomeGridItemCard extends ConsumerWidget {
  const HomeGridItemCard({
    super.key,
    required this.item,
    this.merging = false,
    this.iconHidden = false,
  });

  final HomeGridItem item;
  final bool merging;
  final bool iconHidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (item.type) {
      HomeGridItemType.clock => HomeClockWidget(
        clock: ref.watch(homeClockProvider),
      ),
      HomeGridItemType.app || HomeGridItemType.folder => HomeAppTile(
        item: item,
        merging: merging,
        iconHidden: iconHidden,
      ),
    };
  }
}
