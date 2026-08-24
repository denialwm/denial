import 'dart:async';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../local_apps/local_flutter_application.dart';
import '../../state/shell_controller.dart';
import '../../state/system_status.dart';
import '../launcher_providers.dart';
import '../models/home_battery_discharge_info.dart';
import '../models/desktop_app.dart';
import '../models/home_drag_session.dart';
import '../models/home_clock_info.dart';
import '../models/home_grid_item.dart';
import '../repositories/desktop_apps_repository.dart';
import '../repositories/home_layout_repository.dart';
import '../services/app_launcher.dart';
import 'home_grid_layout.dart';

const Object _unset = Object();

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

final homeDragSessionProvider =
    NotifierProvider<HomeDragSessionController, HomeDragSession?>(
      HomeDragSessionController.new,
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

final homeBatteryDischargeProvider = StreamProvider<HomeBatteryDischargeSeries>(
  (ref) async* {
    while (true) {
      yield await HomeBatteryDischargeSeries.readDefault();
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  },
  isAutoDispose: true,
);

class HomeDragSessionController extends Notifier<HomeDragSession?> {
  @override
  HomeDragSession? build() => null;

  void setSession(HomeDragSession? session) {
    state = session;
  }

  void clear() {
    state = null;
  }
}

class HomeGridState {
  HomeGridState({
    required List<HomeGridItem?> slots,
    this.page = 0,
    this.draggingSourceIndex,
  }) : slots = List.unmodifiable(slots);

  final List<HomeGridItem?> slots;
  final int page;
  final int? draggingSourceIndex;

  HomeGridState copyWith({
    List<HomeGridItem?>? slots,
    int? page,
    Object? draggingSourceIndex = _unset,
  }) {
    return HomeGridState(
      slots: slots ?? this.slots,
      page: page ?? this.page,
      draggingSourceIndex: identical(draggingSourceIndex, _unset)
          ? this.draggingSourceIndex
          : draggingSourceIndex as int?,
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
      final savedLayout = await layoutRepository.readSavedLayout();
      final slots = HomeGridLayout.initialSlotsForApps(
        apps,
        localApps,
        savedLayout,
      );
      if (!_isBuildActive(generation)) {
        return HomeGridState(slots: slots);
      }
      _lastDesktopRefresh = DateTime.now();
      if (_savedLayoutNeedsRefresh(apps, localApps, savedLayout, slots)) {
        unawaited(layoutRepository.saveLayout(slots));
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
        DateTime.now().difference(lastRefresh) < _visibleRefreshMinInterval) {
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

      final currentApps = _appsByGridId(current.slots);
      final refreshedApps = _appsByGridId([
        for (final app in apps) HomeGridItem.app(app),
      ]);

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
      unawaited(ref.read(homeLayoutRepositoryProvider).saveLayout(slots));
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

  void setPage(int page) {
    final current = state.asData?.value;
    if (current == null || current.page == page) {
      return;
    }

    state = AsyncData(current.copyWith(page: page));
  }

  void setDraggingSourceIndex(int? index) {
    final current = state.asData?.value;
    if (current == null || current.draggingSourceIndex == index) {
      return;
    }

    state = AsyncData(current.copyWith(draggingSourceIndex: index));
  }

  bool canMoveSlot(int fromIndex, int toIndex, int pageSize) {
    final current = state.asData?.value;
    if (current == null) {
      return false;
    }

    return HomeGridLayout.canMoveSlot(
      current.slots,
      fromIndex,
      toIndex,
      pageSize,
    );
  }

  int? moveSlot(int fromIndex, int toIndex, int pageSize) {
    final current = state.asData?.value;
    if (current == null) {
      return null;
    }

    final result = HomeGridLayout.moveSlot(
      current.slots,
      fromIndex,
      toIndex,
      pageSize,
    );
    if (result == null) {
      return null;
    }

    state = AsyncData(
      current.copyWith(
        slots: result.slots,
        draggingSourceIndex: result.movedToIndex,
      ),
    );
    unawaited(ref.read(homeLayoutRepositoryProvider).saveLayout(result.slots));
    return result.movedToIndex;
  }

  bool canResizeSlot(int index, int colSpan, int rowSpan, int pageSize) {
    final current = state.asData?.value;
    if (current == null) {
      return false;
    }

    return HomeGridLayout.canResizeSlot(
      current.slots,
      index,
      colSpan,
      rowSpan,
      pageSize,
    );
  }

  void resizeSlot(int index, int colSpan, int rowSpan, int pageSize) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }

    final result = HomeGridLayout.resizeSlot(
      current.slots,
      index,
      colSpan,
      rowSpan,
      pageSize,
    );
    if (result == null) {
      return;
    }

    state = AsyncData(current.copyWith(slots: result.slots));
    unawaited(ref.read(homeLayoutRepositoryProvider).saveLayout(result.slots));
  }
}

Map<String, DesktopApp> _appsByGridId(List<HomeGridItem?> slots) {
  final appsById = <String, DesktopApp>{};
  for (final item in slots) {
    final app = item?.app;
    if (app == null) {
      continue;
    }
    appsById[item!.id] = app;
  }
  return appsById;
}

bool _sameDesktopApp(DesktopApp a, DesktopApp b) {
  if (a.id != b.id ||
      a.name != b.name ||
      a.exec != b.exec ||
      a.desktopPath != b.desktopPath ||
      a.icon != b.icon ||
      a.iconPath != b.iconPath ||
      a.startupWmClass != b.startupWmClass ||
      a.categories.length != b.categories.length) {
    return false;
  }

  for (var index = 0; index < a.categories.length; index += 1) {
    if (a.categories[index] != b.categories[index]) {
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

  final savedIds = <String>{for (final slot in savedLayout) ?slot?.id};
  if (savedIds.contains('widget:frame-time')) {
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
