import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../home_grid_geometry.dart';
import 'home_app_tile.dart';
import 'home_tiles.dart';

/// Every app on home, folders opened, by name, in a full-screen glass sheet
/// that rises from the bottom as [openness] goes from 0 to 1. Pulled down
/// from the top of its list, it follows the finger and [onDrag] and
/// [onDragEnd] report it.
class HomeAppDrawer extends StatefulWidget {
  const HomeAppDrawer({
    super.key,
    required this.openness,
    required this.apps,
    required this.columns,
    required this.onLaunch,
    required this.onDrag,
    required this.onDragEnd,
  });

  final Animation<double> openness;
  final Iterable<HomeGridItem> apps;
  final int columns;

  /// Opens an app from its icon, in global coordinates.
  final void Function(HomeGridItem app, Rect iconRect) onLaunch;

  /// Downward travel, in logical pixels.
  final ValueChanged<double> onDrag;

  /// The release's downward velocity, in logical pixels per second.
  final ValueChanged<double> onDragEnd;

  @override
  State<HomeAppDrawer> createState() => _HomeAppDrawerState();
}

class _HomeAppDrawerState extends State<HomeAppDrawer> {
  final _scroll = ScrollController();

  /// The list is at its top and the finger pulls the sheet instead.
  bool _pulling = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    switch (notification) {
      case OverscrollNotification(:final overscroll, :final dragDetails)
          when dragDetails != null && overscroll < 0:
        _pulling = true;
        widget.onDrag(-overscroll);
      case ScrollUpdateNotification(:final scrollDelta?, :final dragDetails)
          when _pulling && dragDetails != null:
        // Back up while the sheet is down: the sheet rises before the list
        // scrolls.
        widget.onDrag(-scrollDelta);
        if (widget.openness.value < 1) _scroll.jumpTo(0);
      case ScrollEndNotification(:final dragDetails) when _pulling:
        _pulling = false;
        widget.onDragEnd(dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
      case UserScrollNotification(direction: ScrollDirection.idle)
          when _pulling:
        _pulling = false;
        widget.onDragEnd(0);
      default:
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final apps = widget.apps.toList()
      ..sort(
        (a, b) => HomeAppTile.nameOf(
          context,
          a,
        ).toLowerCase().compareTo(HomeAppTile.nameOf(context, b).toLowerCase()),
      );
    return AnimatedBuilder(
      animation: widget.openness,
      builder: (context, sheet) {
        final openness = widget.openness.value;
        return IgnorePointer(
          ignoring: openness == 0,
          child: FractionalTranslation(
            translation: Offset(0, 1 - openness),
            child: Opacity(opacity: openness.clamp(0.0, 1.0), child: sheet),
          ),
        );
      },
      child: Semantics(
        container: true,
        label: context.l10n.homeDrawerSemantics,
        child: ShellBackdropBlur(
          separateChild: true,
          blur: theme.effectivePanelOpacity < 1.0,
          borderRadius: BorderRadius.zero,
          // Dark like the wallpaper under home: the labels are white.
          child: ColoredBox(
            color: ShellMediaColors.darkness.withValues(alpha: 0.55),
            child: NotificationListener<ScrollNotification>(
              onNotification: _scrolled,
              child: GridView.builder(
                controller: _scroll,
                // A list shorter than the screen still takes the pull that
                // closes the sheet.
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                padding: EdgeInsets.fromLTRB(
                  20,
                  padding.top + 72,
                  20,
                  padding.bottom + 72,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: widget.columns,
                  mainAxisExtent: HomeGridLayout.minTileHeight,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: HomeGridLayout.gridGap,
                ),
                itemCount: apps.length,
                itemBuilder: (context, index) => _DrawerTile(
                  key: ValueKey(apps[index].id),
                  app: apps[index],
                  onLaunch: widget.onLaunch,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({super.key, required this.app, required this.onLaunch});

  final HomeGridItem app;
  final void Function(HomeGridItem app, Rect iconRect) onLaunch;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return;
        final rect = MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        );
        onLaunch(app, HomeTileMetrics.iconRectIn(rect));
      },
      child: RepaintBoundary(child: HomeGridItemCard(item: app)),
    );
  }
}
