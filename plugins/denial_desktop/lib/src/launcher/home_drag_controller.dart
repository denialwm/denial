import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/applications.dart';

import 'home_grid_geometry.dart';
import 'home_interactions.dart';

enum HomeDropKind {
  /// Onto a grid cell; an item there trades places with the dragged one.
  cell,

  /// Into the app or folder anchored at the target index.
  merge,

  /// To a position in the open folder.
  folder,
}

typedef HomeDropTarget = ({HomeDropKind kind, int index});

/// The tile a released drag settles into: where, in global coordinates, its
/// icon (or a widget's whole tile) ends, and whether it disappears there.
typedef HomeLanding = ({Rect rect, bool absorbed});

/// A tile lifted off home. Only discrete changes are published here; the
/// finger's position is [HomeDragController.pointer].
@immutable
class HomeDrag {
  const HomeDrag({
    required this.item,
    required this.source,
    required this.inFolder,
    required this.size,
    required this.grip,
    this.target,
    this.displacedId,
    this.displacement = Offset.zero,
    this.landing,
  });

  final HomeGridItem item;

  /// The item's grid anchor, or the anchor of the folder holding it.
  final int source;
  final bool inFolder;

  /// The lifted tile's size, and where in it the finger holds it.
  final Size size;
  final Offset grip;

  final HomeDropTarget? target;

  /// The item that would trade places with the dragged one, and how far it
  /// moves to preview that.
  final String? displacedId;
  final Offset displacement;

  /// Set once released.
  final HomeLanding? landing;

  HomeDrag copyWith({
    HomeDropTarget? target,
    bool clearTarget = false,
    String? displacedId,
    Offset displacement = Offset.zero,
    HomeLanding? landing,
  }) {
    return HomeDrag(
      item: item,
      source: source,
      inFolder: inFolder,
      size: size,
      grip: grip,
      target: clearTarget ? null : target ?? this.target,
      displacedId: displacedId,
      displacement: displacement,
      landing: landing,
    );
  }
}

/// Moves home items: lifts them, finds where they would drop, previews it,
/// commits the drop and hands the tile its landing.
class HomeDragController {
  HomeDragController(this._host);

  final HomeGridHost _host;

  /// A finger resting on an icon for this long makes it a folder target.
  static const Duration mergeDwell = Duration(milliseconds: 260);

  /// A tile resting over a cell this long shows the trade it would make.
  /// Shown at once, the icon a finger heads for would slide away before
  /// it could be reached to make a folder.
  static const Duration reorderDwell = Duration(milliseconds: 220);

  /// Holding a tile at a screen edge this long turns the page.
  static const Duration pageDwell = Duration(milliseconds: 480);
  static const double pageEdge = 36;

  /// A merge needs the dragged icon's center this close to the target's,
  /// relative to the icon size.
  static const double mergeRadius = 0.5;

  final drag = ValueNotifier<HomeDrag?>(null);

  /// The finger, in global coordinates.
  final pointer = ValueNotifier<Offset>(Offset.zero);

  Timer? _mergeTimer;
  int? _mergeCandidate;
  Timer? _previewTimer;
  Timer? _pageTimer;
  int _pageDirection = 0;

  /// A tile is held. A released tile still landing blocks nothing: home
  /// takes taps and new drags while it settles.
  bool get active => drag.value != null && drag.value!.landing == null;
  bool get _released => drag.value?.landing != null;

  void start({
    required HomeGridItem item,
    required int source,
    required bool inFolder,
    required Rect tileRect,
    required Offset global,
  }) {
    _stopTimers();
    // A tile still landing settles at once.
    drag.value = null;
    pointer.value = global;
    drag.value = HomeDrag(
      item: item,
      source: source,
      inFolder: inFolder,
      size: tileRect.size,
      grip: global - tileRect.topLeft,
    );
    _retarget();
  }

  void move(Offset global) {
    if (!active || _released) return;
    pointer.value = global;
    _retarget();
    _followEdges(global);
  }

  /// Retargets after the page changed under a held tile.
  void refresh() {
    if (active && !_released) _retarget();
  }

  /// Drops the tile where it is, or puts it back when [cancelled].
  void end({bool cancelled = false}) {
    final current = drag.value;
    if (current == null || current.landing != null) return;
    final pending = _mergeCandidate;
    _stopTimers();
    // A release on an icon's center is as clear as a rest on it.
    final target = cancelled
        ? null
        : pending != null
        ? (kind: HomeDropKind.merge, index: pending)
        : current.target;
    final landing =
        _commit(current, target) ??
        // Off to another page: it fades where it is.
        (rect: visualRectFor(current, pointer.value), absorbed: true);
    drag.value = current.copyWith(
      target: target,
      clearTarget: target == null,
      landing: landing,
    );
  }

  /// Where the lifted tile draws its icon (a widget: itself) with the finger
  /// at [global].
  static Rect visualRectFor(HomeDrag drag, Offset global) {
    final tile = global - drag.grip & drag.size;
    return drag.item.resizable ? tile : HomeTileMetrics.iconRectIn(tile);
  }

  /// The tile has settled: it shows in its grid cell again.
  void landed() {
    if (drag.value?.landing == null) return;
    _stopTimers();
    drag.value = null;
  }

  /// Ends a drag at once, with no landing: home has gone away. An app
  /// already out of its folder stays out.
  void abandon() {
    final current = drag.value;
    if (current != null && current.landing == null) {
      _commit(current, null);
    }
    _stopTimers();
    drag.value = null;
  }

  void dispose() {
    _stopTimers();
    drag.dispose();
    pointer.dispose();
  }

  void _stopTimers() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _mergeCandidate = null;
    _previewTimer?.cancel();
    _previewTimer = null;
    _pageTimer?.cancel();
    _pageTimer = null;
    _pageDirection = 0;
  }

  // Targeting ----------------------------------------------------------------

  void _retarget() {
    final current = drag.value;
    final grid = _host.grid;
    final geometry = _host.geometry;
    if (current == null || grid == null || geometry == null) return;

    final folder = _host.folders;
    if (current.inFolder && folder.open.value != null) {
      final layout = folder.layout;
      if (layout != null && layout.bounds.inflate(24).contains(pointer.value)) {
        _setTarget((
          kind: HomeDropKind.folder,
          index: layout.positionAt(pointer.value),
        ));
        return;
      }
      // Leaving the panel takes the app out: the grid shows again.
      folder.close();
    }

    final tile =
        _host.globalToGrid(pointer.value) - current.grip & current.size;
    final candidate = _mergeCandidateAt(current, grid, geometry, tile);
    if (candidate != null) {
      if (current.target == (kind: HomeDropKind.merge, index: candidate)) {
        return;
      }
      if (_mergeCandidate != candidate) {
        _mergeCandidate = candidate;
        _mergeTimer?.cancel();
        _mergeTimer = Timer(mergeDwell, () {
          _mergeTimer = null;
          if (_mergeCandidate == candidate && !_released) {
            _mergeCandidate = null;
            _setTarget((kind: HomeDropKind.merge, index: candidate));
          }
        });
      }
      // No trade preview while the finger may be making a folder.
      _previewTimer?.cancel();
      _previewTimer = null;
      _setTarget(null);
      return;
    }
    _mergeCandidate = null;
    _mergeTimer?.cancel();
    _mergeTimer = null;
    final cell = _cellTarget(current, grid, geometry, tile);
    if (cell == current.target) return;
    _setTarget(cell, preview: false);
    _previewTimer?.cancel();
    _previewTimer = cell == null
        ? null
        : Timer(reorderDwell, () {
            _previewTimer = null;
            if (!_released && drag.value?.target == cell) _setTarget(cell);
          });
  }

  /// The app or folder whose icon the dragged app's icon is centered on.
  int? _mergeCandidateAt(
    HomeDrag drag,
    HomeGridState grid,
    HomeGridGeometry geometry,
    Rect tile,
  ) {
    if (!drag.item.isApp) return null;
    final center = HomeTileMetrics.iconRectIn(tile).center;
    final cell = geometry.cellAt(center, grid.page);
    if (cell == null) return null;
    final anchor = HomeGridLayout.anchorForCell(cell, grid.slots);
    // Never onto itself, nor back onto the folder it came from.
    if (anchor == null || anchor == drag.source) return null;
    final target = grid.slots[anchor];
    if (target == null || !(target.isApp || target.isFolder)) return null;
    final icon = HomeTileMetrics.iconRectIn(geometry.itemRect(anchor, target));
    final reach = HomeTileMetrics.icon * mergeRadius;
    return (center - icon.center).distance <= reach ? anchor : null;
  }

  /// The free or tradeable cell the tile overlaps most.
  HomeDropTarget? _cellTarget(
    HomeDrag drag,
    HomeGridState grid,
    HomeGridGeometry geometry,
    Rect tile,
  ) {
    final item = drag.item;
    final pageStart = grid.page * geometry.pageSize;
    int? best;
    var bestOverlap = 0.0;
    var bestDistance = double.infinity;
    for (var row = 0; row <= geometry.rows - item.rowSpan; row += 1) {
      for (
        var column = 0;
        column <= geometry.columns - item.colSpan;
        column += 1
      ) {
        final index = pageStart + row * geometry.columns + column;
        final candidate = geometry.rectAt(
          index,
          colSpan: item.colSpan,
          rowSpan: item.rowSpan,
        );
        final overlap = HomeGridLayout.rectOverlapArea(tile, candidate);
        if (overlap <= 0) continue;
        final allowed = drag.inFolder
            ? HomeGridLayout.anchorForCell(index, grid.slots) == null
            : HomeGridLayout.canMoveSlot(
                grid.slots,
                drag.source,
                index,
                geometry.pageSize,
              );
        if (!allowed) continue;
        final distance = (tile.center - candidate.center).distanceSquared;
        if (overlap > bestOverlap ||
            (overlap == bestOverlap && distance < bestDistance)) {
          best = index;
          bestOverlap = overlap;
          bestDistance = distance;
        }
      }
    }
    return best == null ? null : (kind: HomeDropKind.cell, index: best);
  }

  /// Aims the drop at [target]; with [preview], the item it would trade
  /// places with steps aside to show it.
  void _setTarget(HomeDropTarget? target, {bool preview = true}) {
    final current = drag.value!;
    String? displacedId;
    var displacement = Offset.zero;
    final grid = _host.grid;
    final geometry = _host.geometry;
    if (preview &&
        target?.kind == HomeDropKind.cell &&
        !current.inFolder &&
        grid != null &&
        geometry != null) {
      final partner = HomeGridLayout.swapPartner(
        grid.slots,
        current.source,
        target!.index,
      );
      final displaced = partner == null ? null : grid.slots[partner];
      // Only a partner on the same page can show where it goes.
      if (displaced != null &&
          partner! ~/ geometry.pageSize ==
              current.source ~/ geometry.pageSize) {
        displacedId = displaced.id;
        displacement =
            geometry.rectAt(current.source).topLeft -
            geometry.rectAt(partner).topLeft;
      }
    }
    if (current.target == target &&
        current.displacedId == displacedId &&
        current.displacement == displacement) {
      return;
    }
    drag.value = current.copyWith(
      target: target,
      clearTarget: target == null,
      displacedId: displacedId,
      displacement: displacement,
    );
  }

  void _followEdges(Offset global) {
    final geometry = _host.geometry;
    final current = drag.value;
    if (geometry == null || current == null) return;
    final viewport = _host.gridToGlobal(
      Offset.zero & Size(geometry.width, geometry.height),
    );
    final center = global - current.grip + current.size.center(Offset.zero);
    final direction = center.dx < viewport.left + pageEdge
        ? -1
        : center.dx > viewport.right - pageEdge
        ? 1
        : 0;
    if (direction == _pageDirection) return;
    _pageDirection = direction;
    _pageTimer?.cancel();
    _pageTimer = direction == 0 ? null : _schedulePageTurn(direction);
  }

  Timer _schedulePageTurn(int direction) {
    return Timer(pageDwell, () {
      if (!active || _released || _pageDirection != direction) return;
      _host.turnPage(direction);
      // Holding on turns the next page too.
      _pageTimer = _schedulePageTurn(direction);
    });
  }

  // Dropping -----------------------------------------------------------------

  HomeLanding? _commit(HomeDrag drag, HomeDropTarget? target) {
    final grid = _host.grid;
    final geometry = _host.geometry;
    if (grid == null || geometry == null) return null;
    final controller = _host.gridController;
    final appId = drag.item.id;
    final pageSize = geometry.pageSize;

    switch (target) {
      case (kind: HomeDropKind.folder, :final index):
        controller.reorderFolder(drag.source, appId, index);
        final layout = _host.folders.layout;
        if (layout != null) {
          return (
            rect: HomeTileMetrics.iconRectIn(layout.tileRect(index)),
            absorbed: false,
          );
        }
        return null;
      case (kind: HomeDropKind.merge, :final index):
        final into = grid.slots[index];
        final name = _host.folderNameFor([?into, drag.item]);
        if (drag.inFolder) {
          controller.moveFromFolderInto(
            drag.source,
            appId,
            index,
            folderName: name,
          );
        } else {
          controller.merge(drag.source, index, folderName: name);
        }
        final icon = HomeTileMetrics.iconRectIn(geometry.rectAt(index));
        return (
          rect: _host.gridToGlobal(
            Rect.fromCenter(
              center: icon.center,
              width: icon.width * 0.3,
              height: icon.height * 0.3,
            ),
          ),
          absorbed: true,
        );
      case (kind: HomeDropKind.cell, :final index):
        if (drag.inFolder) {
          controller.moveOutOfFolder(drag.source, appId, index, pageSize);
        } else {
          controller.moveSlot(drag.source, index, pageSize);
        }
      case null:
        final layout = _host.folders.layout;
        if (drag.inFolder &&
            _host.folders.open.value != null &&
            layout != null) {
          // Still over its open folder: back to its place there.
          final position =
              grid.slots[drag.source]?.folderApps.indexWhere(
                (app) => app.id == appId,
              ) ??
              -1;
          if (position < 0) return null;
          return (
            rect: HomeTileMetrics.iconRectIn(layout.tileRect(position)),
            absorbed: false,
          );
        }
        if (drag.inFolder) {
          // Out of the folder, onto this page's first free cell.
          controller.moveOutOfFolder(
            drag.source,
            appId,
            grid.page * pageSize,
            pageSize,
          );
        }
    }
    return _landingOnGrid(drag.item, geometry);
  }

  /// Where [item] now sits on the visible page, or a fade where it is when
  /// it went to another page.
  HomeLanding? _landingOnGrid(HomeGridItem item, HomeGridGeometry geometry) {
    final grid = _host.grid;
    if (grid == null) return null;
    final index = grid.slots.indexWhere((slot) => slot?.id == item.id);
    if (index < 0 || index ~/ geometry.pageSize != grid.page) {
      return null;
    }
    final rect = geometry.itemRect(index, item);
    return (
      rect: _host.gridToGlobal(
        item.resizable ? rect : HomeTileMetrics.iconRectIn(rect),
      ),
      absorbed: false,
    );
  }
}
