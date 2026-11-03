import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

/// An application's home icon at the size its parent gives it: the desktop
/// icon file, or a local application's glyph in the accent color.
///
/// Every place that draws an app as an icon uses this, so a transition that
/// starts or ends on a home icon draws exactly the same pixels.
class LauncherIcon extends StatelessWidget {
  const LauncherIcon({
    super.key,
    this.iconPath,
    this.icon,
    this.rasterize = false,
  });

  LauncherIcon.of(HomeGridItem item, {Key? key, bool rasterize = false})
    : this(
        key: key,
        iconPath: item.app?.iconPath,
        icon: item.localApp?.icon,
        rasterize: rasterize,
      );

  final String? iconPath;
  final IconData? icon;

  /// Draws a glyph icon from an image while it scales: a font glyph drawn at
  /// every animated size would be rasterized again for each.
  final bool rasterize;

  /// A glyph fills this share of the icon box, as in the 85 px home icon.
  static const double glyphFraction = 72 / 85;

  @override
  Widget build(BuildContext context) {
    final glyph = icon;
    if (glyph == null) {
      return AppIconImage(iconPath: iconPath);
    }
    final symbol = ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Icon(
            glyph,
            size: constraints.biggest.shortestSide * glyphFraction,
            color: ShellTheme.of(context).accentPalette.primary,
          ),
        ),
      ),
    );
    if (!rasterize) return symbol;
    return SnapshotWidget(
      controller: _alwaysSnapshot,
      mode: SnapshotMode.permissive,
      child: symbol,
    );
  }
}

final _alwaysSnapshot = SnapshotController(allowSnapshotting: true);
