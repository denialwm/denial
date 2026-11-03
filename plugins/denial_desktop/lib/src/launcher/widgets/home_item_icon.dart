import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/applications.dart';

import '../home_grid_geometry.dart';
import 'launcher_icon.dart';

/// The icon of an app or folder on home, filling its parent's square.
class HomeItemIcon extends StatelessWidget {
  const HomeItemIcon({super.key, required this.item, this.rasterize = false});

  final HomeGridItem item;
  final bool rasterize;

  @override
  Widget build(BuildContext context) {
    return item.isFolder
        ? HomeFolderIcon(apps: item.folderApps)
        : LauncherIcon.of(item, rasterize: rasterize);
  }
}

/// A folder's plate, showing its first nine apps in a 3 x 3 grid.
class HomeFolderIcon extends StatelessWidget {
  const HomeFolderIcon({super.key, required this.apps});

  final List<HomeGridItem> apps;

  static const int _side = 3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide;
        final padding = size * 0.13;
        final gap = size * 0.05;
        final mini = (size - padding * 2 - gap * (_side - 1)) / _side;
        return HomeFolderPlate(
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Stack(
              children: [
                for (var index = 0; index < apps.length && index < 9; index++)
                  Positioned(
                    left: (index % _side) * (mini + gap),
                    top: (index ~/ _side) * (mini + gap),
                    width: mini,
                    height: mini,
                    child: LauncherIcon.of(apps[index]),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The translucent rounded square behind a folder's apps. A merge target
/// grows one behind its icon before it becomes a folder.
class HomeFolderPlate extends StatelessWidget {
  const HomeFolderPlate({super.key, this.child});

  final Widget? child;

  static const Color fill = Color(0x38ffffff);
  static const Color outline = Color(0x2effffff);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: outline),
          borderRadius: BorderRadius.circular(
            constraints.biggest.shortestSide *
                HomeTileMetrics.iconRadiusFraction,
          ),
        ),
        child: child,
      ),
    );
  }
}
