import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import '../../launcher/home_icon_locator.dart' show launcherAppIdentity;

/// The application identity shown above a recents card.
typedef _CardApplication = ({String? name, String? iconPath, IconData? icon});

final _cardApplication = Provider.autoDispose.family<_CardApplication, String>((
  ref,
  appId,
) {
  final local = ref.watch(localFlutterApplicationRegistryProvider)[appId];
  if (local != null) {
    return (name: local.title, iconPath: null, icon: local.icon);
  }
  final id = launcherAppIdentity(appId);
  final launcher = ref.watch(appLauncherProvider);
  for (final item
      in ref.watch(homeGridControllerProvider).value?.apps ??
          const <HomeGridItem>[]) {
    final app = item.app;
    if (app == null) continue;
    if (launcher
        .expectedWindowAppIds(app)
        .any((candidate) => launcherAppIdentity(candidate) == id)) {
      return (name: app.name, iconPath: app.iconPath, icon: null);
    }
  }
  return (name: null, iconPath: null, icon: null);
});

/// The app icon and name above a card, aligned to its start edge.
class OverviewCardLabel extends ConsumerWidget {
  const OverviewCardLabel({
    super.key,
    required this.window,
    this.trailingSpace = 0,
  });

  static const double height = iconSize;
  static const double iconSize = 48;
  static const double gap = 12;

  final DenialWindow window;

  /// Room kept free at the end of the row, for a button over it.
  final double trailingSpace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final application = ref.watch(_cardApplication(window.appId));
    final colors = context.shellColors;
    final icon = application.icon;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox.square(
            dimension: iconSize,
            child: icon != null
                ? FittedBox(child: Icon(icon, color: colors.textPrimary))
                : AppIconImage(iconPath: application.iconPath),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              application.name ?? localizedWindowTitle(context, window),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          if (trailingSpace > 0) SizedBox(width: trailingSpace),
        ],
      ),
    );
  }
}
