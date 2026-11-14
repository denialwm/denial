import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';

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
/// from the top of its list, it follows the finger up and down until the
/// finger lifts, and [onDrag] and [onDragEnd] report it.
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

  /// The finger that moves the list, or the sheet once it pulls.
  int? _pointer;

  /// The list was at its top and the finger moved down: the finger holds
  /// the sheet, and the list stays still, until it lifts.
  bool _pulling = false;
  late VelocityTracker _velocity;

  late final _physics = _SheetPullPhysics(pulling: () => _pulling);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _velocity.addPosition(event.timeStamp, event.position);
    if (!_pulling &&
        event.delta.dy > 0 &&
        _scroll.hasClients &&
        _scroll.position.pixels <= _scroll.position.minScrollExtent) {
      _pulling = true;
    }
    if (_pulling) widget.onDrag(event.delta.dy);
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    if (!_pulling) return;
    _pulling = false;
    widget.onDragEnd(
      event is PointerUpEvent ? _velocity.getVelocity().pixelsPerSecond.dy : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final names = {
      for (final app in widget.apps)
        app: HomeAppTile.nameOf(context, app).toLowerCase(),
    };
    final apps = names.keys.toList()
      ..sort((a, b) => names[a]!.compareTo(names[b]!));
    return AnimatedBuilder(
      animation: widget.openness,
      builder: (context, sheet) {
        final openness = widget.openness.value;
        // No fade: glass under an opacity layer has nothing to blur. Closed,
        // it paints nothing, yet a finger that pulled it down holds it.
        return Offstage(
          offstage: openness == 0,
          child: FractionalTranslation(
            translation: Offset(0, 1 - openness),
            child: sheet,
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
            child: Listener(
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: GridView.builder(
                controller: _scroll,
                physics: _physics,
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

/// The list's scrolling, held still while the finger pulls the sheet. A
/// list shorter than the screen still takes the drag.
class _SheetPullPhysics extends ClampingScrollPhysics {
  const _SheetPullPhysics({required this.pulling, super.parent});

  final bool Function() pulling;

  @override
  _SheetPullPhysics applyTo(ScrollPhysics? ancestor) =>
      _SheetPullPhysics(pulling: pulling, parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      pulling() ? 0 : super.applyPhysicsToUserOffset(position, offset);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => pulling() ? null : super.createBallisticSimulation(position, velocity);
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
