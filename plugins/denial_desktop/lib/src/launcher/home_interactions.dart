import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/applications.dart';

import 'home_drag_controller.dart';
import 'home_grid_geometry.dart';
import 'home_resize_controller.dart';

/// What home's tiles ask of the surface, and the state they present.
abstract interface class HomeInteractions {
  HomeDragController get drag;
  HomeResizeController get resize;
  HomeFolderController get folders;

  /// The items window transitions draw in home's place.
  ValueListenable<Set<String>> get hiddenItems;

  /// Opens [app] from its icon at [iconRect], in global coordinates.
  void launch(HomeGridItem app, Rect iconRect);

  void openFolder(HomeGridItem folder, Rect iconRect);

  /// A long press on [item], anchored at [index] (or held in the folder
  /// at [index]), whose tile is at [tileRect] in global coordinates.
  void hold(
    HomeGridItem item,
    int index,
    Rect tileRect,
    Offset pointer, {
    bool inFolder = false,
  });
}

/// Provides [HomeInteractions] to the tiles below.
class HomeInteractionScope extends InheritedWidget {
  const HomeInteractionScope({
    super.key,
    required this.interactions,
    required super.child,
  });

  final HomeInteractions interactions;

  static HomeInteractions of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HomeInteractionScope>()!
      .interactions;

  @override
  bool updateShouldNotify(HomeInteractionScope oldWidget) =>
      interactions != oldWidget.interactions;
}

/// What the gesture controllers need from the surface.
abstract interface class HomeGridHost {
  /// The grid as last loaded, null while loading.
  HomeGridState? get grid;
  HomeGridController get gridController;

  /// The pager's layout, null before its first.
  HomeGridGeometry? get geometry;

  Offset globalToGrid(Offset global);
  Rect gridToGlobal(Rect rect);

  /// Moves to the next page in [direction], when there is one.
  void turnPage(int direction);

  /// The name a new folder of [apps] starts with.
  String folderNameFor(List<HomeGridItem> apps);

  HomeFolderController get folders;
}

/// The open folder.
@immutable
class HomeOpenFolder {
  const HomeOpenFolder({required this.id, required this.origin});

  final String id;

  /// The folder's icon on the grid, in global coordinates: the panel grows
  /// out of it and shrinks back into it.
  final Rect origin;
}

/// Where the open folder's panel draws its apps, in global coordinates.
abstract interface class HomeFolderLayout {
  Rect get bounds;

  /// The position under [global], clamped to the folder's apps.
  int positionAt(Offset global);
  Rect tileRect(int position);
}

class HomeFolderController {
  final open = ValueNotifier<HomeOpenFolder?>(null);

  /// The panel's layout while it is shown.
  HomeFolderLayout? layout;

  void show(String id, Rect origin) =>
      open.value = HomeOpenFolder(id: id, origin: origin);

  void close() => open.value = null;

  void dispose() => open.dispose();
}
