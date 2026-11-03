import 'dart:async';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../local_apps/local_flutter_application.dart';
import '../../platform/denial_bridge_provider.dart';
import '../../state/system_status.dart';
import '../launcher_providers.dart';
import '../models/desktop_app.dart';
import '../models/home_clock_info.dart';
import '../models/home_grid_item.dart';
import '../repositories/desktop_apps_repository.dart';
import '../repositories/home_layout_repository.dart';
import '../services/app_launcher.dart';
import 'home_grid_layout.dart';

final desktopAppsRepositoryProvider = Provider<DesktopAppsRepository>((ref) {
  return DesktopAppsRepository(paths: ref.watch(runtimePathsProvider));
});

final homeLayoutRepositoryProvider = Provider<HomeLayoutRepository>((ref) {
  return HomeLayoutRepository(paths: ref.watch(runtimePathsProvider));
});

final appLauncherProvider = Provider<AppLauncher>((ref) {
  return AppLauncher(bridge: ref.watch(denialBridgeProvider));
});

final homeGridControllerProvider =
    AsyncNotifierProvider<HomeGridController, HomeGridState>(
      HomeGridController.new,
    );

final homeClockProvider = Provider<HomeClockInfo>((ref) {
  final locale = HomeClockInfo.localeFromEnvironment(
    ref.watch(runtimePathsProvider).environment,
  );
  return HomeClockInfo.fromShell(
    now: ref.watch(clockProvider).value ?? DateTime.now(),
    locale: locale,
    power: ref.watch(effectivePowerStatusProvider),
  );
}, isAutoDispose: true);

class HomeGridState {
  HomeGridState({required List<HomeGridItem?> slots, this.page = 0})
    : slots = List.unmodifiable(slots);

  HomeGridState._({required this.slots, required this.page});

  final List<HomeGridItem?> slots;
  final int page;

  /// Every application on the grid, folder contents included.
  Iterable<HomeGridItem> get apps => HomeGridLayout.appsIn(slots);

  HomeGridState copyWith({List<HomeGridItem?>? slots, int? page}) {
    return HomeGridState._(
      slots: slots == null ? this.slots : List.unmodifiable(slots),
      page: page ?? this.page,
    );
  }
}

class HomeGridController extends AsyncNotifier<HomeGridState> {
  static const Duration _periodicRefreshInterval = Duration(minutes: 5);
  static const Duration _visibleRefreshMinInterval = Duration(seconds: 45);
  static const Duration _filesystemRefreshDebounce = Duration(
    milliseconds: 200,
  );

  Timer? _desktopRefreshTimer;
  Timer? _activationRefreshTimer;
  Timer? _filesystemRefreshTimer;
  DesktopAppsWatcher? _desktopAppsWatcher;
  DateTime? _lastDesktopRefresh;
  bool _desktopRefreshInFlight = false;
  bool _desktopRefreshTriggersStarted = false;
  bool _desktopAppsDirty = false;
  bool _launcherActive = true;
  int _buildGeneration = 0;

  /// The orientation the slots are laid out for; null while they belong to
  /// whichever orientation the grid shows first.
  HomeOrientation? _orientation;

  /// Every orientation's saved layout, the shown one as of its last save.
  Map<HomeOrientation, List<HomeLayoutSlot?>> _layouts = {};

  @override
  Future<HomeGridState> build() async {
    final generation = ++_buildGeneration;
    _desktopRefreshTimer = null;
    _activationRefreshTimer = null;
    _filesystemRefreshTimer = null;
    _desktopAppsWatcher = null;
    _lastDesktopRefresh = null;
    _desktopRefreshInFlight = false;
    _desktopRefreshTriggersStarted = false;
    _desktopAppsDirty = false;
    _launcherActive = true;
    ref.onDispose(() {
      if (_buildGeneration == generation) {
        _buildGeneration++;
      }
      _activationRefreshTimer?.cancel();
      _activationRefreshTimer = null;
      _desktopRefreshTimer?.cancel();
      _desktopRefreshTimer = null;
      _filesystemRefreshTimer?.cancel();
      _filesystemRefreshTimer = null;
      unawaited(_desktopAppsWatcher?.dispose());
      _desktopAppsWatcher = null;
      _desktopRefreshTriggersStarted = false;
    });
    final appsRepository = ref.watch(desktopAppsRepositoryProvider);
    final layoutRepository = ref.watch(homeLayoutRepositoryProvider);
    final localApps = ref
        .watch(localFlutterApplicationRegistryProvider)
        .applications
        .toList(growable: false);
    try {
      final apps = await _loadApplications(appsRepository, reason: 'initial');
      final saved = await layoutRepository.readSavedLayouts();
      // Portrait first, which is where a phone starts.
      final orientation = HomeOrientation.values
          .where(saved.layouts.containsKey)
          .firstOrNull;
      final savedLayout = orientation == null
          ? saved.unassigned
          : saved.layouts[orientation];
      final slots = HomeGridLayout.initialSlotsForApps(
        apps,
        localApps,
        savedLayout,
      );
      if (!_isBuildActive(generation)) {
        return HomeGridState(slots: slots);
      }
      _orientation = orientation;
      _layouts = {...saved.layouts};
      _lastDesktopRefresh = DateTime.now();
      if (_savedLayoutNeedsRefresh(apps, localApps, savedLayout, slots)) {
        _save(slots);
      }
      unawaited(_startDesktopRefreshTriggers(generation, appsRepository));
      return HomeGridState(slots: slots);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> refreshDesktopApps({String reason = 'manual'}) async {
    if (state.asData?.value == null) {
      return;
    }

    if (!_launcherActive && reason != 'manual') {
      return;
    }

    final lastRefresh = _lastDesktopRefresh;
    if (reason == 'launcher-visible' &&
        lastRefresh != null &&
        // A complete watcher already reports every top-level change, so
        // returning home spends no isolate rescanning unchanged entries.
        ((_desktopAppsWatcher?.complete ?? false) ||
            DateTime.now().difference(lastRefresh) <
                _visibleRefreshMinInterval)) {
      return;
    }

    if (_desktopRefreshInFlight) {
      return;
    }

    final generation = _buildGeneration;
    _desktopAppsDirty = false;
    _desktopRefreshInFlight = true;
    try {
      final apps = await _loadApplications(
        ref.read(desktopAppsRepositoryProvider),
        reason: reason,
      );
      if (!_isBuildActive(generation)) {
        return;
      }
      _lastDesktopRefresh = DateTime.now();
      final current = state.asData?.value;
      if (current == null) {
        return;
      }

      final currentApps = _appsByGridId(current.apps);
      final refreshedApps = _appsByGridId(apps.map(HomeGridItem.app));

      final addedIds = refreshedApps.keys
          .where((id) => !currentApps.containsKey(id))
          .toList(growable: false);
      final removedIds = currentApps.keys
          .where((id) => !refreshedApps.containsKey(id))
          .toList(growable: false);
      final updatedIds = refreshedApps.keys
          .where(
            (id) =>
                currentApps.containsKey(id) &&
                !_sameDesktopApp(currentApps[id]!, refreshedApps[id]!),
          )
          .toList(growable: false);

      if (addedIds.isEmpty && removedIds.isEmpty && updatedIds.isEmpty) {
        return;
      }

      final localApps = ref
          .read(localFlutterApplicationRegistryProvider)
          .applications;
      final slots = HomeGridLayout.refreshSlotsForApps(
        current.slots,
        apps,
        localApps,
      );
      state = AsyncData(current.copyWith(slots: slots));
      _save(slots);
    } finally {
      if (_isBuildActive(generation)) {
        _desktopRefreshInFlight = false;
        if (_desktopAppsDirty && _launcherActive) {
          _scheduleFilesystemRefresh();
        }
      }
    }
  }

  void setLauncherActive(bool active) {
    if (_launcherActive == active) {
      return;
    }

    _launcherActive = active;
    _activationRefreshTimer?.cancel();
    _activationRefreshTimer = null;
    if (active) {
      if (_desktopAppsDirty) {
        _scheduleFilesystemRefresh();
        return;
      }
      final generation = _buildGeneration;
      _activationRefreshTimer = Timer(const Duration(milliseconds: 750), () {
        if (!_isBuildActive(generation)) {
          return;
        }
        _activationRefreshTimer = null;
        unawaited(refreshDesktopApps(reason: 'launcher-visible'));
      });
    }
  }

  Future<void> _startDesktopRefreshTriggers(
    int generation,
    DesktopAppsRepository repository,
  ) async {
    try {
      if (_desktopRefreshTriggersStarted) {
        return;
      }
      _desktopRefreshTriggersStarted = true;
      _desktopRefreshTimer = Timer.periodic(_periodicRefreshInterval, (_) {
        if (!_isBuildActive(generation) || !_launcherActive) {
          return;
        }
        unawaited(refreshDesktopApps(reason: 'timer'));
      });
      final watcher = await repository.watchApplications(
        onChanged: () {
          if (!_isBuildActive(generation)) {
            return;
          }
          _desktopAppsDirty = true;
          if (_launcherActive) {
            _scheduleFilesystemRefresh();
          }
        },
      );
      if (!_isBuildActive(generation) || !_desktopRefreshTriggersStarted) {
        await watcher.dispose();
        return;
      }
      _desktopAppsWatcher = watcher;
    } on Object {
      // Filesystem notifications are best effort. Keep the periodic timer as
      // the fallback when the platform cannot establish a watcher.
    }
  }

  void _scheduleFilesystemRefresh() {
    _filesystemRefreshTimer?.cancel();
    _filesystemRefreshTimer = Timer(_filesystemRefreshDebounce, () {
      _filesystemRefreshTimer = null;
      unawaited(refreshDesktopApps(reason: 'filesystem'));
    });
  }

  bool _isBuildActive(int generation) =>
      ref.mounted && generation == _buildGeneration;

  Future<List<DesktopApp>> _loadApplications(
    DesktopAppsRepository repository, {
    required String reason,
  }) {
    return Isolate.run(
      repository.loadApplications,
      debugName: 'denia-launcher-desktop-$reason',
    );
  }

  /// The orientation the grid shows, null before it first lays out.
  HomeOrientation? get orientation => _orientation;

  /// Lays the grid out for [orientation], in pages of [pageSize]: its saved
  /// layout, or the shown one reflowed into the new pages when it has none.
  void arrange(HomeOrientation orientation, int pageSize) {
    final current = state.asData?.value;
    final shown = _orientation;
    if (current == null || orientation == shown) {
      return;
    }
    _orientation = orientation;
    if (shown == null) {
      // The slots are this orientation's layout from now on.
      _save(current.slots);
      return;
    }

    _layouts[shown] = _layoutOf(current.slots);
    final saved = _layouts[orientation];
    final slots = saved == null
        ? HomeGridLayout.reflowSlots(current.slots, pageSize)
        : HomeGridLayout.initialSlotsForApps(
            [for (final item in current.apps) ?item.app],
            ref.read(localFlutterApplicationRegistryProvider).applications,
            saved,
          );
    state = AsyncData(current.copyWith(slots: slots));
    _save(slots);
  }

  void setPage(int page) {
    final current = state.asData?.value;
    if (current == null || current.page == page) {
      return;
    }

    state = AsyncData(current.copyWith(page: page));
  }

  bool canMoveSlot(int fromIndex, int toIndex, int pageSize) {
    final slots = state.asData?.value.slots;
    return slots != null &&
        HomeGridLayout.canMoveSlot(slots, fromIndex, toIndex, pageSize);
  }

  void moveSlot(int fromIndex, int toIndex, int pageSize) {
    _update(
      (slots) => HomeGridLayout.moveSlot(slots, fromIndex, toIndex, pageSize),
    );
  }

  bool canResizeSlot(
    int index,
    int anchor,
    int colSpan,
    int rowSpan,
    int pageSize,
  ) {
    final slots = state.asData?.value.slots;
    return slots != null &&
        HomeGridLayout.canResizeSlot(
          slots,
          index,
          anchor,
          colSpan,
          rowSpan,
          pageSize,
        );
  }

  void resizeSlot(
    int index,
    int anchor,
    int colSpan,
    int rowSpan,
    int pageSize,
  ) {
    _update(
      (slots) => HomeGridLayout.resizeSlot(
        slots,
        index,
        anchor,
        colSpan,
        rowSpan,
        pageSize,
      ),
    );
  }

  bool canMerge(int fromIndex, int targetIndex) {
    final slots = state.asData?.value.slots;
    return slots != null &&
        HomeGridLayout.canMerge(slots, fromIndex, targetIndex);
  }

  /// Drops the app at [fromIndex] on the app or folder at [targetIndex]. A
  /// new folder is named [folderName].
  void merge(int fromIndex, int targetIndex, {required String folderName}) {
    _update(
      (slots) => HomeGridLayout.merge(
        slots,
        fromIndex,
        targetIndex,
        folderId: HomeGridLayout.newFolderId(slots),
        folderName: folderName,
      ),
    );
  }

  void moveOutOfFolder(
    int folderIndex,
    String appId,
    int toIndex,
    int pageSize,
  ) {
    _update(
      (slots) => HomeGridLayout.moveOutOfFolder(
        slots,
        folderIndex,
        appId,
        toIndex,
        pageSize,
      ),
    );
  }

  void moveFromFolderInto(
    int folderIndex,
    String appId,
    int targetIndex, {
    required String folderName,
  }) {
    _update(
      (slots) => HomeGridLayout.moveFromFolderInto(
        slots,
        folderIndex,
        appId,
        targetIndex,
        folderId: HomeGridLayout.newFolderId(slots),
        folderName: folderName,
      ),
    );
  }

  void reorderFolder(int folderIndex, String appId, int position) {
    _update(
      (slots) =>
          HomeGridLayout.reorderFolder(slots, folderIndex, appId, position),
    );
  }

  void renameFolder(int folderIndex, String name) {
    _update((slots) => HomeGridLayout.renameFolder(slots, folderIndex, name));
  }

  /// Applies one layout operation and saves its result; a null result is a
  /// change that was not possible.
  void _update(List<HomeGridItem?>? Function(List<HomeGridItem?> slots) edit) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    final slots = edit(current.slots);
    if (slots == null) {
      return;
    }
    state = AsyncData(current.copyWith(slots: slots));
    _save(slots);
  }

  /// Saves [slots] as the shown orientation's layout, beside the others.
  void _save(List<HomeGridItem?> slots) {
    final layout = _layoutOf(slots);
    final orientation = _orientation;
    if (orientation != null) {
      _layouts[orientation] = layout;
    }
    unawaited(
      ref
          .read(homeLayoutRepositoryProvider)
          .saveLayouts(
            orientation == null
                ? HomeSavedLayouts(unassigned: layout)
                : HomeSavedLayouts(layouts: {..._layouts}),
          ),
    );
  }
}

List<HomeLayoutSlot?> _layoutOf(List<HomeGridItem?> slots) => [
  for (final slot in slots) slot == null ? null : HomeLayoutSlot.of(slot),
];

Map<String, DesktopApp> _appsByGridId(Iterable<HomeGridItem> items) {
  return <String, DesktopApp>{for (final item in items) item.id: ?item.app};
}

bool _sameDesktopApp(DesktopApp a, DesktopApp b) {
  if (a.id != b.id ||
      a.name != b.name ||
      a.exec != b.exec ||
      a.desktopPath != b.desktopPath ||
      a.icon != b.icon ||
      a.iconPath != b.iconPath ||
      a.startupWmClass != b.startupWmClass ||
      a.categories.length != b.categories.length ||
      a.keywords.length != b.keywords.length) {
    return false;
  }

  for (var index = 0; index < a.categories.length; index += 1) {
    if (a.categories[index] != b.categories[index]) {
      return false;
    }
  }
  for (var index = 0; index < a.keywords.length; index += 1) {
    if (a.keywords[index] != b.keywords[index]) {
      return false;
    }
  }
  return true;
}

bool _savedLayoutNeedsRefresh(
  List<DesktopApp> apps,
  Iterable<LocalFlutterApplication> localApps,
  List<HomeLayoutSlot?>? savedLayout,
  List<HomeGridItem?> slots,
) {
  if (savedLayout == null || savedLayout.length != slots.length) {
    return true;
  }

  final savedIds = <String>{
    for (final slot in savedLayout) ...?slot?.children,
    for (final slot in savedLayout) ?slot?.id,
  };
  if (savedIds.contains('widget:frame-time') ||
      savedIds.contains('widget:battery-discharge')) {
    return true;
  }

  final currentAppIds = <String>{
    for (final app in apps) 'app:${app.id}',
    for (final app in localApps) 'local:${app.id}',
  };
  if (!savedIds.containsAll(currentAppIds)) {
    return true;
  }

  return savedIds
      .where((id) => id.startsWith('app:') || id.startsWith('local:'))
      .any((id) => !currentAppIds.contains(id));
}
