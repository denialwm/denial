import '../../local_apps/local_flutter_application.dart';
import 'desktop_app.dart';

enum HomeGridItemType { clock, app, folder }

/// Home keeps one layout for each orientation, so arranging one never
/// rearranges the other.
enum HomeOrientation { portrait, landscape }

/// One saved grid slot. A folder lists its applications in [children].
class HomeLayoutSlot {
  const HomeLayoutSlot({
    required this.id,
    this.colSpan,
    this.rowSpan,
    this.name,
    this.children,
  });

  /// The saved form of [item].
  factory HomeLayoutSlot.of(HomeGridItem item) => switch (item.type) {
    HomeGridItemType.app => HomeLayoutSlot(id: item.id),
    HomeGridItemType.clock => HomeLayoutSlot(
      id: item.id,
      colSpan: item.colSpan,
      rowSpan: item.rowSpan,
    ),
    HomeGridItemType.folder => HomeLayoutSlot(
      id: item.id,
      name: item.folderName,
      children: [for (final app in item.folderApps) app.id],
    ),
  };

  final String id;
  final int? colSpan;
  final int? rowSpan;
  final String? name;
  final List<String>? children;
}

class HomeGridItem {
  const HomeGridItem._({
    required this.type,
    required this.id,
    required this.colSpan,
    required this.rowSpan,
    this.app,
    this.localApp,
    this.folderName,
    this.folderApps = const <HomeGridItem>[],
  });

  factory HomeGridItem.clock({
    int colSpan = defaultClockColSpan,
    int rowSpan = defaultClockRowSpan,
  }) {
    return HomeGridItem._(
      type: HomeGridItemType.clock,
      id: clockId,
      colSpan: colSpan.clamp(clockMinColSpan, clockMaxColSpan).toInt(),
      rowSpan: rowSpan.clamp(clockMinRowSpan, clockMaxRowSpan).toInt(),
    );
  }

  factory HomeGridItem.app(DesktopApp desktopApp) {
    return HomeGridItem._(
      type: HomeGridItemType.app,
      id: 'app:${desktopApp.id}',
      colSpan: 1,
      rowSpan: 1,
      app: desktopApp,
    );
  }

  factory HomeGridItem.localApp(LocalFlutterApplication localApp) {
    return HomeGridItem._(
      type: HomeGridItemType.app,
      id: 'local:${localApp.id}',
      colSpan: 1,
      rowSpan: 1,
      localApp: localApp,
    );
  }

  /// A folder of applications. Folders hold apps only, never widgets or
  /// other folders.
  factory HomeGridItem.folder({
    required String id,
    required String name,
    required List<HomeGridItem> apps,
  }) {
    assert(apps.every((item) => item.isApp));
    return HomeGridItem._(
      type: HomeGridItemType.folder,
      id: id,
      colSpan: 1,
      rowSpan: 1,
      folderName: name,
      folderApps: List<HomeGridItem>.unmodifiable(apps),
    );
  }

  static const String clockId = 'widget:clock';
  static const String folderIdPrefix = 'folder:';

  static const int defaultClockColSpan = 2;
  static const int defaultClockRowSpan = 1;
  static const int clockMinColSpan = 2;
  static const int clockMaxColSpan = 4;
  static const int clockMinRowSpan = 1;
  static const int clockMaxRowSpan = 3;

  /// The largest span of any item. Cell lookups search no further back.
  static const int largestColSpan = clockMaxColSpan;
  static const int largestRowSpan = clockMaxRowSpan;

  final HomeGridItemType type;
  final String id;
  final int colSpan;
  final int rowSpan;
  final DesktopApp? app;
  final LocalFlutterApplication? localApp;
  final String? folderName;
  final List<HomeGridItem> folderApps;

  bool get isApp => type == HomeGridItemType.app;
  bool get isFolder => type == HomeGridItemType.folder;
  bool get resizable => type == HomeGridItemType.clock;

  /// The applications this item launches: itself, or a folder's contents.
  Iterable<HomeGridItem> get apps => switch (type) {
    HomeGridItemType.app => <HomeGridItem>[this],
    HomeGridItemType.folder => folderApps,
    HomeGridItemType.clock => const <HomeGridItem>[],
  };

  int get minColSpan => resizable ? clockMinColSpan : 1;
  int get maxColSpan => resizable ? clockMaxColSpan : 1;
  int get minRowSpan => resizable ? clockMinRowSpan : 1;
  int get maxRowSpan => resizable ? clockMaxRowSpan : 1;

  HomeGridItem resize({required int colSpan, required int rowSpan}) {
    if (!resizable) {
      return this;
    }
    return HomeGridItem.clock(colSpan: colSpan, rowSpan: rowSpan);
  }

  HomeGridItem withFolder({String? name, List<HomeGridItem>? apps}) {
    assert(isFolder);
    return HomeGridItem.folder(
      id: id,
      name: name ?? folderName!,
      apps: apps ?? folderApps,
    );
  }
}
