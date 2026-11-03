import 'dart:math' as math;
import 'dart:ui';

import '../../local_apps/local_flutter_application.dart';
import '../models/desktop_app.dart';
import '../models/home_grid_item.dart';

/// Pure operations on the home grid's slot list.
///
/// Slots are a row-major list of cells, [columns] wide and paged every
/// `pageSize` cells. An item occupies the cell at its index (its anchor) and
/// the cells its span covers; covered cells stay null. Every operation returns
/// a new list, or null when the change is not possible.
class HomeGridLayout {
  const HomeGridLayout._();

  /// Column count for the current viewport. 4 is the phone-tuned baseline;
  /// [columnsForViewport] raises it on wide panels (set once per layout pass
  /// by the home surface) so pages stay full-bleed instead of overflowing rows.
  static int columns = 4;

  static const double gridGap = 22;
  static const int minPages = 2;

  /// Tile content is fixed-size (92px icon + label ~= 131 tall), so cells
  /// gain nothing from growing: cap their footprint and let wide panels get
  /// more columns/rows instead. Phone-width viewports stay at 4 columns
  /// with uncapped-equivalent sizes.
  static const double maxTileWidth = 224;
  static const double maxTileHeight = 240;

  /// A cell never gets shorter than its icon and label.
  static const double minTileHeight = 131;
  static const int minRows = 3;
  static const int maxRows = 7;

  /// Column count so tiles stay at or under [maxTileWidth].
  static int columnsForViewport(double width) {
    final cols = ((width + gridGap) / (maxTileWidth + gridGap)).ceil();
    return cols.clamp(4, 14).toInt();
  }

  /// The rows of [tileHeight] that fit in [height]: never more than fit,
  /// and at least one.
  static int rowsForHeight(double height, double tileHeight) {
    // Cells sized to fill the height exactly must not lose a row to rounding.
    final rows = ((height + gridGap) / (tileHeight + gridGap) + 1e-6).floor();
    return rows.clamp(1, maxRows).toInt();
  }

  static int pageCountForSlots(List<HomeGridItem?> slots, int pageSize) {
    if (pageSize <= 0) {
      return minPages;
    }
    return math.max(minPages, (slots.length / pageSize).ceil());
  }

  /// Every application on the grid, folder contents included, in slot order.
  static Iterable<HomeGridItem> appsIn(List<HomeGridItem?> slots) sync* {
    for (final item in slots) {
      if (item != null) yield* item.apps;
    }
  }

  // Catalog ------------------------------------------------------------------

  static List<HomeGridItem?> initialSlotsForApps(
    List<DesktopApp> apps,
    Iterable<LocalFlutterApplication> localApps,
    List<HomeLayoutSlot?>? savedLayout,
  ) {
    final appsById = _appItemsById(apps, localApps);
    final clock = HomeGridItem.clock();
    final used = <String>{};
    var slots = <HomeGridItem?>[];

    for (var index = 0; index < (savedLayout?.length ?? 0); index += 1) {
      final slot = savedLayout![index];
      if (slot == null || used.contains(slot.id)) {
        continue;
      }
      final HomeGridItem? item;
      if (slot.id == HomeGridItem.clockId) {
        item = clock.resize(
          colSpan: slot.colSpan ?? clock.colSpan,
          rowSpan: slot.rowSpan ?? clock.rowSpan,
        );
      } else if (slot.id.startsWith(HomeGridItem.folderIdPrefix)) {
        item = _folderOrSingleApp(slot.id, slot.name ?? '', [
          for (final id in {...?slot.children})
            if (!used.contains(id)) ?appsById[id],
        ]);
      } else {
        item = appsById[slot.id];
      }
      if (item == null) {
        continue;
      }

      final placed = placeItemAt(slots, index, item);
      if (identical(placed, slots)) {
        continue;
      }
      slots = placed;
      used
        ..add(item.id)
        ..addAll(item.apps.map((app) => app.id));
    }

    if (!used.contains(clock.id)) {
      slots = placeItemInFirstFreeSlot(slots, clock);
    }
    for (final item in appsById.values) {
      if (used.contains(item.id)) {
        continue;
      }
      slots = placeItemAfter(slots, savedLayout?.length ?? 0, item);
    }
    return slots;
  }

  static List<HomeGridItem?> refreshSlotsForApps(
    List<HomeGridItem?> currentSlots,
    List<DesktopApp> apps,
    Iterable<LocalFlutterApplication> localApps,
  ) {
    final appsById = _appItemsById(apps, localApps);
    final placedIds = <String>{};
    var next = <HomeGridItem?>[];

    for (var index = 0; index < currentSlots.length; index += 1) {
      final current = currentSlots[index];
      if (current == null || placedIds.contains(current.id)) {
        continue;
      }

      final item = switch (current.type) {
        HomeGridItemType.clock => current,
        HomeGridItemType.app => appsById[current.id],
        HomeGridItemType.folder => _folderOrSingleApp(
          current.id,
          current.folderName!,
          [
            for (final app in current.folderApps)
              if (!placedIds.contains(app.id)) ?appsById[app.id],
          ],
        ),
      };
      if (item == null) {
        continue;
      }

      final placed = placeItemAt(next, index, item);
      next = identical(placed, next)
          ? placeItemInFirstFreeSlot(next, item)
          : placed;
      placedIds
        ..add(item.id)
        ..addAll(item.apps.map((app) => app.id));
    }

    for (final item in appsById.values) {
      if (placedIds.contains(item.id)) {
        continue;
      }
      next = placeItemAfter(next, currentSlots.length, item);
      placedIds.add(item.id);
    }
    return next;
  }

  static Map<String, HomeGridItem> _appItemsById(
    List<DesktopApp> apps,
    Iterable<LocalFlutterApplication> localApps,
  ) {
    return <String, HomeGridItem>{
      for (final app in apps) 'app:${app.id}': HomeGridItem.app(app),
      for (final app in localApps)
        'local:${app.id}': HomeGridItem.localApp(app),
    };
  }

  /// A folder needs two apps; with one left it becomes that app.
  static HomeGridItem? _folderOrSingleApp(
    String id,
    String name,
    List<HomeGridItem> apps,
  ) {
    return switch (apps.length) {
      0 => null,
      1 => apps.single,
      _ => HomeGridItem.folder(id: id, name: name, apps: apps),
    };
  }

  /// [slots] placed one after another, in order, into the current columns
  /// and pages of [pageSize]: the first layout of an orientation, from the
  /// other's. A widget taller or wider than a page shrinks to fit it.
  static List<HomeGridItem?> reflowSlots(
    List<HomeGridItem?> slots,
    int pageSize,
  ) {
    final rows = math.max(1, pageSize ~/ columns);
    var next = <HomeGridItem?>[];
    var index = 0;
    for (final slot in slots) {
      if (slot == null) continue;
      final item = slot.resize(
        colSpan: math.min(slot.colSpan, columns),
        rowSpan: math.min(slot.rowSpan, rows),
      );
      while (!canPlaceAt(
        next,
        index,
        item,
        pageSize,
        ignoreAnchors: const {},
      )) {
        index += 1;
      }
      next = ensureListLength(next, cellsFor(index, item).last + 1);
      next[index] = item;
      index += 1;
    }
    return next;
  }

  // Placement ----------------------------------------------------------------

  static List<HomeGridItem?> placeItemAt(
    List<HomeGridItem?> slots,
    int index,
    HomeGridItem item,
  ) {
    if (!itemFitsAtColumn(item, index)) {
      return slots;
    }

    final cells = cellsFor(index, item);
    final blocked = cells.any((cell) => anchorForCell(cell, slots) != null);
    if (blocked) {
      return slots;
    }

    final next = ensureListLength([...slots], cells.last + 1);
    next[index] = item;
    return next;
  }

  static List<HomeGridItem?> placeItemInFirstFreeSlot(
    List<HomeGridItem?> slots,
    HomeGridItem item,
  ) {
    return placeItemAfter(slots, 0, item);
  }

  static List<HomeGridItem?> placeItemAfter(
    List<HomeGridItem?> slots,
    int startIndex,
    HomeGridItem item,
  ) {
    var next = [...slots];
    for (var index = math.max(0, startIndex); ; index += 1) {
      if (!itemFitsAtColumn(item, index)) {
        continue;
      }
      final cells = cellsFor(index, item);
      final blocked = cells.any((cell) => anchorForCell(cell, next) != null);
      if (blocked) {
        continue;
      }
      next = ensureListLength(next, cells.last + 1);
      next[index] = item;
      return next;
    }
  }

  /// The first free cell for a single-cell item at or after [index] on its
  /// page, else anywhere after it.
  static int freeCellNear(List<HomeGridItem?> slots, int index, int pageSize) {
    final pageStart = index - index % pageSize;
    for (var cell = index; cell < pageStart + pageSize; cell += 1) {
      if (anchorForCell(cell, slots) == null) return cell;
    }
    for (var cell = pageStart; cell < index; cell += 1) {
      if (anchorForCell(cell, slots) == null) return cell;
    }
    for (var cell = pageStart + pageSize; ; cell += 1) {
      if (anchorForCell(cell, slots) == null) return cell;
    }
  }

  static bool itemFitsAtColumn(HomeGridItem item, int index) {
    final column = index % columns;
    return column + item.colSpan <= columns;
  }

  static bool itemFitsInPage(
    int index,
    HomeGridItem item,
    int pageSize, {
    int? columns,
  }) {
    final columnCount = columns ?? HomeGridLayout.columns;
    if (index < 0 ||
        pageSize <= 0 ||
        index % columnCount + item.colSpan > columnCount) {
      return false;
    }
    final lastCell =
        index + (item.rowSpan - 1) * columnCount + item.colSpan - 1;
    return index ~/ pageSize == lastCell ~/ pageSize;
  }

  static List<int> cellsFor(int index, HomeGridItem item, {int? columns}) {
    columns ??= HomeGridLayout.columns;
    final baseRow = index ~/ columns;
    final baseColumn = index % columns;
    return [
      for (var row = 0; row < item.rowSpan; row += 1)
        for (var column = 0; column < item.colSpan; column += 1)
          (baseRow + row) * columns + baseColumn + column,
    ];
  }

  static int? anchorForCell(int cell, List<HomeGridItem?> slots) {
    if (cell < 0) return null;
    final row = cell ~/ columns;
    final column = cell % columns;
    // Only anchors in the largest item's footprint can cover this cell.
    // Hit testing and drag placement allocate no temporary cell lists.
    final firstRow = math.max(0, row - HomeGridItem.largestRowSpan + 1);
    final firstColumn = math.max(0, column - HomeGridItem.largestColSpan + 1);
    for (var anchorRow = firstRow; anchorRow <= row; anchorRow++) {
      for (
        var anchorColumn = firstColumn;
        anchorColumn <= column;
        anchorColumn++
      ) {
        final index = anchorRow * columns + anchorColumn;
        if (index >= slots.length) break;
        final item = slots[index];
        if (item != null &&
            row - anchorRow < item.rowSpan &&
            column - anchorColumn < item.colSpan) {
          return index;
        }
      }
    }
    return null;
  }

  static List<HomeGridItem?> ensureListLength(
    List<HomeGridItem?> slots,
    int length,
  ) {
    if (slots.length >= length) {
      return slots;
    }
    return [...slots, for (var i = slots.length; i < length; i += 1) null];
  }

  static bool canPlaceAt(
    List<HomeGridItem?> slots,
    int index,
    HomeGridItem item,
    int pageSize, {
    required Set<int> ignoreAnchors,
  }) {
    if (!itemFitsInPage(index, item, pageSize)) {
      return false;
    }

    for (final cell in cellsFor(index, item)) {
      final occupant = anchorForCell(cell, slots);
      if (occupant != null && !ignoreAnchors.contains(occupant)) {
        return false;
      }
    }
    return true;
  }

  // Moving -------------------------------------------------------------------

  /// Moves the item at [fromIndex] so its anchor lands on [toIndex]. An item
  /// already there trades places with it.
  static bool canMoveSlot(
    List<HomeGridItem?> slots,
    int fromIndex,
    int toIndex,
    int pageSize,
  ) {
    if (fromIndex == toIndex ||
        fromIndex < 0 ||
        toIndex < 0 ||
        fromIndex >= slots.length) {
      return false;
    }

    final source = slots[fromIndex];
    if (source == null) {
      return false;
    }

    final targetAnchor = anchorForCell(toIndex, slots) ?? toIndex;
    if (targetAnchor == fromIndex) {
      return false;
    }
    final target = targetAnchor < slots.length ? slots[targetAnchor] : null;
    if (target == null) {
      return canPlaceAt(
        slots,
        toIndex,
        source,
        pageSize,
        ignoreAnchors: {fromIndex},
      );
    }

    return canPlaceAt(
          slots,
          targetAnchor,
          source,
          pageSize,
          ignoreAnchors: {fromIndex, targetAnchor},
        ) &&
        canPlaceAt(
          slots,
          fromIndex,
          target,
          pageSize,
          ignoreAnchors: {fromIndex, targetAnchor},
        );
  }

  /// The anchor an item displaced by a move from [fromIndex] to [toIndex]
  /// had, or null when that cell is empty.
  static int? swapPartner(
    List<HomeGridItem?> slots,
    int fromIndex,
    int toIndex,
  ) {
    final anchor = anchorForCell(toIndex, slots);
    return anchor == fromIndex ? null : anchor;
  }

  static List<HomeGridItem?>? moveSlot(
    List<HomeGridItem?> slots,
    int fromIndex,
    int toIndex,
    int pageSize,
  ) {
    if (!canMoveSlot(slots, fromIndex, toIndex, pageSize)) {
      return null;
    }

    final source = slots[fromIndex]!;
    final targetAnchor = anchorForCell(toIndex, slots) ?? toIndex;
    final target = targetAnchor < slots.length ? slots[targetAnchor] : null;
    final requiredLength = [
      ...cellsFor(targetAnchor, source),
      if (target != null) ...cellsFor(fromIndex, target),
    ].reduce(math.max);

    final next = ensureListLength([...slots], requiredLength + 1);
    next[fromIndex] = target;
    next[targetAnchor] = source;
    return next;
  }

  // Resizing -----------------------------------------------------------------

  /// Whether the item at [index] can take [colSpan] x [rowSpan] with its
  /// anchor moved to [anchor]: a widget grows from its left or top edge by
  /// moving its anchor. The anchor stays on the item's page.
  static bool canResizeSlot(
    List<HomeGridItem?> slots,
    int index,
    int anchor,
    int colSpan,
    int rowSpan,
    int pageSize,
  ) {
    if (index < 0 || index >= slots.length || anchor < 0) {
      return false;
    }

    final source = slots[index];
    if (source == null || !source.resizable) {
      return false;
    }
    if (anchor ~/ pageSize != index ~/ pageSize ||
        colSpan < source.minColSpan ||
        colSpan > source.maxColSpan ||
        rowSpan < source.minRowSpan ||
        rowSpan > source.maxRowSpan) {
      return false;
    }

    final resized = source.resize(colSpan: colSpan, rowSpan: rowSpan);
    return canPlaceAt(slots, anchor, resized, pageSize, ignoreAnchors: {index});
  }

  static List<HomeGridItem?>? resizeSlot(
    List<HomeGridItem?> slots,
    int index,
    int anchor,
    int colSpan,
    int rowSpan,
    int pageSize,
  ) {
    if (!canResizeSlot(slots, index, anchor, colSpan, rowSpan, pageSize)) {
      return null;
    }

    final resized = slots[index]!.resize(colSpan: colSpan, rowSpan: rowSpan);
    final next = ensureListLength([
      ...slots,
    ], cellsFor(anchor, resized).last + 1);
    next[index] = null;
    next[anchor] = resized;
    return next;
  }

  // Folders ------------------------------------------------------------------

  /// Whether dropping the item at [fromIndex] on [targetIndex] makes or fills
  /// a folder: an app dropped on another app or on a folder.
  static bool canMerge(
    List<HomeGridItem?> slots,
    int fromIndex,
    int targetIndex,
  ) {
    if (fromIndex == targetIndex ||
        fromIndex < 0 ||
        fromIndex >= slots.length ||
        targetIndex < 0 ||
        targetIndex >= slots.length) {
      return false;
    }
    final source = slots[fromIndex];
    final target = slots[targetIndex];
    return source != null &&
        source.isApp &&
        target != null &&
        (target.isApp || target.isFolder);
  }

  /// Drops the app at [fromIndex] on [targetIndex]. Two apps become a new
  /// folder [folderId] named [folderName] in the target's cell; a folder
  /// takes the app as its last entry.
  static List<HomeGridItem?>? merge(
    List<HomeGridItem?> slots,
    int fromIndex,
    int targetIndex, {
    required String folderId,
    required String folderName,
  }) {
    if (!canMerge(slots, fromIndex, targetIndex)) {
      return null;
    }
    final next = [...slots];
    next[targetIndex] = _withApp(
      slots[targetIndex]!,
      slots[fromIndex]!,
      folderId: folderId,
      folderName: folderName,
    );
    next[fromIndex] = null;
    return next;
  }

  static HomeGridItem _withApp(
    HomeGridItem target,
    HomeGridItem app, {
    required String folderId,
    required String folderName,
  }) {
    return target.isFolder
        ? target.withFolder(apps: [...target.folderApps, app])
        : HomeGridItem.folder(
            id: folderId,
            name: folderName,
            apps: [target, app],
          );
  }

  /// Takes [appId] out of the folder at [folderIndex]. A folder left with
  /// one app becomes that app, in the folder's cell.
  static ({List<HomeGridItem?> slots, HomeGridItem app})? takeFromFolder(
    List<HomeGridItem?> slots,
    int folderIndex,
    String appId,
  ) {
    final folder = folderIndex >= 0 && folderIndex < slots.length
        ? slots[folderIndex]
        : null;
    if (folder == null || !folder.isFolder) {
      return null;
    }
    final app = folder.folderApps.where((item) => item.id == appId).firstOrNull;
    if (app == null) {
      return null;
    }
    final next = [...slots];
    next[folderIndex] = _folderOrSingleApp(folder.id, folder.folderName!, [
      for (final item in folder.folderApps)
        if (item.id != appId) item,
    ]);
    return (slots: next, app: app);
  }

  /// Moves [appId] out of the folder at [folderIndex] to the grid. It lands
  /// on [toIndex] when that cell is free, else in the nearest free cell.
  static List<HomeGridItem?>? moveOutOfFolder(
    List<HomeGridItem?> slots,
    int folderIndex,
    String appId,
    int toIndex,
    int pageSize,
  ) {
    final taken = takeFromFolder(slots, folderIndex, appId);
    if (taken == null) {
      return null;
    }
    final cell = freeCellNear(taken.slots, toIndex, pageSize);
    final next = ensureListLength([...taken.slots], cell + 1);
    next[cell] = taken.app;
    return next;
  }

  /// Moves [appId] from the folder at [folderIndex] into the app or folder
  /// at [targetIndex].
  static List<HomeGridItem?>? moveFromFolderInto(
    List<HomeGridItem?> slots,
    int folderIndex,
    String appId,
    int targetIndex, {
    required String folderId,
    required String folderName,
  }) {
    if (folderIndex == targetIndex) {
      return null;
    }
    final target = targetIndex >= 0 && targetIndex < slots.length
        ? slots[targetIndex]
        : null;
    if (target == null || !(target.isApp || target.isFolder)) {
      return null;
    }
    final taken = takeFromFolder(slots, folderIndex, appId);
    if (taken == null) {
      return null;
    }
    final next = [...taken.slots];
    next[targetIndex] = _withApp(
      target,
      taken.app,
      folderId: folderId,
      folderName: folderName,
    );
    return next;
  }

  /// Moves [appId] to [position] within the folder at [folderIndex].
  static List<HomeGridItem?>? reorderFolder(
    List<HomeGridItem?> slots,
    int folderIndex,
    String appId,
    int position,
  ) {
    final folder = slots[folderIndex];
    if (folder == null || !folder.isFolder) {
      return null;
    }
    final apps = [...folder.folderApps];
    final from = apps.indexWhere((item) => item.id == appId);
    if (from < 0) {
      return null;
    }
    final to = position.clamp(0, apps.length - 1).toInt();
    if (from == to) {
      return null;
    }
    apps.insert(to, apps.removeAt(from));
    return [...slots]..[folderIndex] = folder.withFolder(apps: apps);
  }

  static List<HomeGridItem?>? renameFolder(
    List<HomeGridItem?> slots,
    int folderIndex,
    String name,
  ) {
    final folder = slots[folderIndex];
    if (folder == null || !folder.isFolder || folder.folderName == name) {
      return null;
    }
    return [...slots]..[folderIndex] = folder.withFolder(name: name);
  }

  /// A folder id no slot uses yet.
  static String newFolderId(List<HomeGridItem?> slots) {
    final used = {for (final item in slots) ?item?.id};
    var seed = DateTime.now().microsecondsSinceEpoch;
    while (used.contains(
      '${HomeGridItem.folderIdPrefix}${seed.toRadixString(36)}',
    )) {
      seed += 1;
    }
    return '${HomeGridItem.folderIdPrefix}${seed.toRadixString(36)}';
  }

  static double rectOverlapArea(Rect a, Rect b) {
    final left = math.max(a.left, b.left);
    final right = math.min(a.right, b.right);
    final top = math.max(a.top, b.top);
    final bottom = math.min(a.bottom, b.bottom);
    if (right <= left || bottom <= top) {
      return 0;
    }
    return (right - left) * (bottom - top);
  }
}
