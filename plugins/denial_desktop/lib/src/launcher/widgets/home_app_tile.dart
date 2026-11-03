import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../home_grid_geometry.dart';
import 'home_item_icon.dart';

/// An app or folder as home shows it: its icon over its name.
class HomeAppTile extends StatelessWidget {
  const HomeAppTile({
    super.key,
    required this.item,
    this.merging = false,
    this.iconHidden = false,
  });

  final HomeGridItem item;

  /// A dragged app rests on this one: a folder plate grows behind it.
  final bool merging;

  /// A window transition draws the icon in its place; the name stays.
  final bool iconHidden;

  static String nameOf(BuildContext context, HomeGridItem item) =>
      item.folderName ??
      item.localApp?.titleFor(context) ??
      item.app?.name ??
      '';

  /// Keeps white labels legible over any wallpaper.
  static const List<Shadow> labelShadows = [
    Shadow(color: ShellMediaColors.shadow, blurRadius: 8, offset: Offset(0, 1)),
  ];

  static const TextStyle labelStyle = TextStyle(
    color: ShellMediaColors.lightForeground,
    fontSize: 13,
    height: 1.06,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    shadows: labelShadows,
  );

  @override
  Widget build(BuildContext context) {
    final name = nameOf(context, item);
    return Semantics(
      button: true,
      label: item.isFolder
          ? context.l10n.homeFolderApps(name, item.folderApps.length)
          : name,
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox.square(
            dimension: HomeTileMetrics.iconBox,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (item.isApp) _MergePlate(visible: merging),
                if (!iconHidden)
                  SizedBox.square(
                    dimension: HomeTileMetrics.icon,
                    child: AnimatedScale(
                      // A folder about to take an app swells to receive it.
                      scale: merging && item.isFolder ? 1.1 : 1,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: HomeItemIcon(item: item),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: HomeTileMetrics.labelGap),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: labelStyle,
          ),
        ],
      ),
    );
  }
}

/// The folder plate that grows behind an app a dragged app rests on.
class _MergePlate extends StatelessWidget {
  const _MergePlate({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 140),
      child: AnimatedScale(
        scale: visible ? 1 : 0.86,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        child: const SizedBox.square(
          dimension: HomeTileMetrics.icon * 1.18,
          child: HomeFolderPlate(),
        ),
      ),
    );
  }
}
