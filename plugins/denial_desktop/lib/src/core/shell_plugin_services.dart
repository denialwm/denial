import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:typed_data';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../desktop/desktop_workspace.dart';
import '../desktop/system_tray_module.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../state/desktop_visibility.dart';
import '../state/window_emphasis.dart';
import '../state/quick_settings.dart';

import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import '../widgets/notification_media.dart';
import '../state/phone_desk.dart';

final _monitorBounds = Provider.autoDispose.family<Rect?, int>((ref, id) {
  for (final output in ref.watch(deskDisplayLayoutProvider)?.outputs ?? []) {
    if (output.monitorId == id) return output.logicalRect;
  }
  return null;
});

final _accent = Provider.autoDispose(
  (ref) => ref.watch(shellAccentProvider).color,
);
final _volume = Provider.autoDispose(
  (ref) => ref.watch(quickSettingsProvider.select((state) => state.volume)),
);
final _connectedWifi = Provider.autoDispose(
  (ref) => ref.watch(
    networkConnectivityProvider.select(
      (state) => state.snapshot.connectedNetwork,
    ),
  ),
);
final _workspacesEnabled = Provider.autoDispose(
  (ref) => ref.watch(
    shellSettingsProvider.select(
      (settings) => settings.layout.workspacesEnabled,
    ),
  ),
);
final _trayVisible = Provider.autoDispose(
  (ref) => ref.watch(systemTrayProvider.select((items) => items.isNotEmpty)),
);
final _trayItemIds = Provider.autoDispose<List<String>>(
  (ref) =>
      List.unmodifiable(ref.watch(systemTrayProvider).map((item) => item.id)),
);
final _workspace = Provider.autoDispose.family<WorkspaceStatus, int>((
  ref,
  monitorId,
) {
  final desktop = ref.watch(desktopWorkspaceProvider);
  return WorkspaceStatus(
    count: ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.layout.workspaceCount,
      ),
    ),
    active: desktop.activeWorkspaceFor(monitorId),
    occupied: desktop.placements.values
        .where(
          (placement) =>
              !placement.minimized && placement.monitorId == monitorId,
        )
        .map((placement) => placement.workspaceId)
        .toSet(),
  );
});
final _mediaCommands = Provider<MediaCommands>(
  (ref) => _MediaCommands(ref.watch(mediaPlayerServiceProvider)),
);

final _applications = Provider<List<LaunchableApplication>>((ref) {
  final grid = ref.watch(homeGridControllerProvider).value;
  final launcher = ref.watch(appLauncherProvider);
  final local = ref.watch(localFlutterApplicationRegistryProvider);
  return List.unmodifiable([
    for (final item in grid?.apps ?? const <HomeGridItem>[])
      if (item.app case final app?)
        LaunchableApplication(
          id: desktopApplicationRecentId(app.id),
          appId: app.id,
          name: app.name,
          windowAppIds: launcher.expectedWindowAppIds(app),
        ),
    for (final app in local.applications)
      LaunchableApplication(
        id: localApplicationRecentId(app.id),
        appId: app.id,
        name: app.title,
        windowAppIds: List.unmodifiable([app.id]),
      ),
  ]);
});

final _windows = Provider.autoDispose.family<List<ApplicationWindow>, int>((
  ref,
  monitorId,
) {
  final shell = ref.watch(referenceShellProvider);
  final desktop = ref.watch(desktopWorkspaceProvider);
  final desktopVisible = ref.watch(desktopVisibleProvider);
  final tiled = ref.watch(
    shellSettingsProvider.select(
      (settings) =>
          settings.layout.windowLayout != DesktopWindowLayout.stacking,
    ),
  );
  return List.unmodifiable([
    for (final window in shell.desk.openAppWindows)
      if (window.monitorId == monitorId &&
          (window.minimized ||
              window.pinned ||
              window.workspaceId == desktop.activeWorkspaceFor(monitorId)))
        ApplicationWindow(
          id: window.objectId,
          appId: window.appId,
          title: window.title.isEmpty ? window.appId : window.title,
          active:
              !desktopVisible &&
              shell.deskForegroundObjectId == window.objectId &&
              !window.minimized,
          minimized: window.minimized,
          tiled: tiled,
          previewSize: window.presentationCoordinateRect.size,
        ),
  ]);
});

/// Adapts native-owned shell services to the public plugin boundary.
/// Provider lifetimes and mutations remain owned by their existing controllers.
final class DesktopShellServices implements ShellServices {
  const DesktopShellServices({
    required this.ref,
    required this.onOpenPowerSettings,
    required this.onToggleLauncher,
    required this.onOpenDashboard,
    required this.onToggleDashboard,
  });
  final WidgetRef ref;
  final VoidCallback onOpenPowerSettings;
  final VoidCallback onToggleLauncher;
  final VoidCallback onOpenDashboard;
  final VoidCallback onToggleDashboard;

  // Stateless adapters with the same ref and callbacks are interchangeable;
  // the scene keeps an equal one so its identity survives rebuilds.
  @override
  bool operator ==(Object other) =>
      other is DesktopShellServices &&
      identical(ref, other.ref) &&
      onOpenPowerSettings == other.onOpenPowerSettings &&
      onToggleLauncher == other.onToggleLauncher &&
      onOpenDashboard == other.onOpenDashboard &&
      onToggleDashboard == other.onToggleDashboard;

  @override
  int get hashCode => Object.hash(
    ref,
    onOpenPowerSettings,
    onToggleLauncher,
    onOpenDashboard,
    onToggleDashboard,
  );

  @override
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId) =>
      _windows(monitorId);
  @override
  ProviderListenable<List<LaunchableApplication>> get applications =>
      _applications;

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) async {
    if (ref.read(referenceShellProvider).locked) return false;
    ref.read(windowEmphasisProvider.notifier).clear();
    ref.read(desktopVisibleProvider.notifier).restore();
    bool started = false;
    for (final item
        in ref.read(homeGridControllerProvider).value?.apps ??
            const <HomeGridItem>[]) {
      final app = item.app;
      if (app == null || desktopApplicationRecentId(app.id) != id) continue;
      started = await ref.read(appLauncherProvider).launch(app);
      break;
    }
    if (!started && ref.context.mounted) {
      final layout = ref.read(deskDisplayLayoutProvider);
      final output =
          layout?.outputs
              .where((output) => output.monitorId == monitorId)
              .firstOrNull ??
          layout?.mainOutput;
      for (final app
          in ref.read(localFlutterApplicationRegistryProvider).applications) {
        if (localApplicationRecentId(app.id) != id) continue;
        final size = ref.read(desktopWorkspaceProvider).viewSize;
        started = ref
            .read(localFlutterApplicationLauncherProvider)
            .launch(
              app.id,
              availableBounds: output != null
                  ? layout!.workAreaOf(output)
                  : Offset.zero & (size.isEmpty ? const Size(1280, 720) : size),
              title: app.titleFor(ref.context),
            );
        break;
      }
    }
    if (started && ref.context.mounted) {
      ref.read(applicationRecentsProvider.notifier).record(id);
    }
    return started;
  }

  @override
  void activateWindow(int id) {
    ref.read(windowEmphasisProvider.notifier).clear();
    ref.read(desktopVisibleProvider.notifier).restore();
    for (final window in ref.read(referenceShellProvider).desk.openAppWindows) {
      if (window.objectId != id) continue;
      ref.read(desktopWorkspaceProvider.notifier).activate(id);
      ref.read(referenceShellProvider.notifier).focusWindow(window);
      return;
    }
  }

  @override
  void minimizeWindow(int id) {
    ref.read(windowEmphasisProvider.notifier).clear();
    for (final window in ref.read(referenceShellProvider).desk.openAppWindows) {
      if (window.objectId != id) continue;
      ref.read(denialBridgeProvider).minimizeWindow(window);
      return;
    }
  }

  @override
  void toggleLauncher() => onToggleLauncher();

  @override
  void openDashboard() => onOpenDashboard();
  @override
  void toggleDashboard() => onToggleDashboard();
  @override
  void toggleDesktop() => ref.read(desktopVisibleProvider.notifier).toggle();
  @override
  ProviderListenable<bool> get desktopVisible => desktopVisibleProvider;
  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      _ApplicationIcon(appId: appId);

  @override
  Widget buildWindowPreview(BuildContext context, int windowId) =>
      _WindowPreview(windowId: windowId);
  @override
  VoidCallback emphasizeWindow(int windowId, {required int monitorId}) => ref
      .read(windowEmphasisProvider.notifier)
      .begin(windowId, monitorId: monitorId);
  @override
  ProviderListenable<Rect?> monitorBounds(int monitorId) =>
      _monitorBounds(monitorId);

  @override
  ProviderListenable<BatteryStatus> get battery => batteryProvider;
  @override
  ProviderListenable<double> get volume => _volume;
  @override
  ProviderListenable<WifiNetwork?> get connectedWifi => _connectedWifi;
  @override
  void beginVolumeInteraction() =>
      ref.read(quickSettingsProvider.notifier).beginVolumeInteraction();
  @override
  void setVolume(double value) =>
      ref.read(quickSettingsProvider.notifier).setDashboardVolume(value);
  @override
  void commitVolume(double value) =>
      ref.read(quickSettingsProvider.notifier).commitDashboardVolume(value);
  @override
  ProviderListenable<LoadSeries> get cpu => cpuUsageProvider;
  @override
  ProviderListenable<List<GpuLoad>> get gpus => gpuUsageProvider;
  @override
  ProviderListenable<AsyncValue<DateTime>> get clock => clockProvider;
  @override
  ProviderListenable<AsyncValue<MprisPlaybackState>> get media =>
      mediaPlaybackProvider;
  @override
  ProviderListenable<MediaCommands> get mediaCommands => _mediaCommands;
  @override
  ProviderListenable<Color> get accent => _accent;
  @override
  ProviderListenable<bool> get workspacesEnabled => _workspacesEnabled;
  @override
  ProviderListenable<bool> get trayVisible => _trayVisible;
  @override
  ProviderListenable<List<String>> get trayItemIds => _trayItemIds;
  @override
  ProviderListenable<WorkspaceStatus> workspace(int monitorId) =>
      _workspace(monitorId);
  @override
  ProviderListenable<AsyncValue<Uint8List?>> imageBytes(String path) =>
      notificationStaticImageProvider(path);
  @override
  void switchWorkspace({required int monitorId, required int workspaceId}) =>
      ref
          .read(denialBridgeProvider)
          .switchWorkspace(monitorId: monitorId, workspaceId: workspaceId);
  @override
  void openPowerSettings() => onOpenPowerSettings();
  @override
  MouseCursor get normalCursor => ShellMouseCursors.normal;
  @override
  MouseCursor get linkCursor => ShellMouseCursors.link;
  @override
  ShellStrings strings(BuildContext context) => _Strings(context);
  @override
  Widget buildSystemTray(
    BuildContext context, {
    required bool horizontal,
    bool wrap = false,
    Color? foregroundColor,
    List<String>? itemIds,
  }) => _DesktopSystemTray(
    horizontal: horizontal,
    wrap: wrap,
    foregroundColor: foregroundColor,
    itemIds: itemIds,
  );
}

class _WindowPreview extends ConsumerWidget {
  const _WindowPreview({required this.windowId});
  final int windowId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(referenceShellProvider);
    final window = shell.openAppWindowsByObjectId[windowId];
    if (shell.locked || window == null) return const SizedBox.shrink();
    final size = window.presentationCoordinateRect.size;
    if (window.isLocalFlutter ||
        size.isEmpty ||
        window.mainVisibleSurfaceIds.isEmpty) {
      return Center(
        child: SizedBox.square(
          dimension: 48,
          child: _ApplicationIcon(appId: window.appId),
        ),
      );
    }
    // Share the actual client textures, including subsurfaces and buffer
    // transforms. DesktopInputLayoutPublisher already keeps active-workspace
    // and minimized client surfaces presentation-visible. No screenshots,
    // client resize, or duplicate local Flutter application host is involved.
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox.fromSize(
              size: size,
              child: WindowSurfaceTree(
                window: window,
                filterQuality: FilterQuality.low,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ApplicationIcon extends ConsumerWidget {
  const _ApplicationIcon({required this.appId});
  final String appId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(localFlutterApplicationRegistryProvider)[appId];
    if (local != null) return Icon(local.icon, size: 28);
    final path = ref.watch(
      homeGridControllerProvider.select((value) {
        final id = appId.toLowerCase().replaceFirst(RegExp(r'\.desktop$'), '');
        for (final item in value.value?.apps ?? const <HomeGridItem>[]) {
          final app = item.app;
          if (app == null) continue;
          if (app.id.toLowerCase().replaceFirst(RegExp(r'\.desktop$'), '') ==
                  id ||
              app.startupWmClass?.toLowerCase() == id) {
            return app.iconPath;
          }
        }
        return null;
      }),
    );
    return AppIconImage(iconPath: path);
  }
}

class _DesktopSystemTray extends ConsumerWidget {
  const _DesktopSystemTray({
    required this.horizontal,
    required this.wrap,
    this.foregroundColor,
    this.itemIds,
  });
  final bool horizontal;
  final bool wrap;
  final Color? foregroundColor;
  final List<String>? itemIds;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(systemTrayProvider);
    final byId = {for (final item in items) item.id: item};
    return SystemTrayModule(
      wrap: wrap,
      horizontal: horizontal,
      accent: foregroundColor ?? context.shellTheme.accent,
      items: itemIds == null
          ? items
          : [for (final id in itemIds!.toSet()) ?byId[id]],
    );
  }
}

final class _MediaCommands implements MediaCommands {
  const _MediaCommands(this.service);
  final MediaPlayerService service;
  @override
  MprisPlaybackState get current => service.current;
  @override
  Future<void> previous() => service.previous();
  @override
  Future<void> playPause() => service.playPause();
  @override
  Future<void> next() => service.next();
}

// Instances are created during build and not retained by the adapter.
final class _Strings implements ShellStrings {
  const _Strings(this.context);
  final BuildContext context;
  @override
  String time(DateTime value) => localizedTime(context, value);
  @override
  String shortDate(DateTime value) => localizedShortDate(context, value);
  @override
  String batteryLine(String state, int capacity) =>
      localizedBatteryLine(context.l10n, state, capacity);
  @override
  String numberValue(int value) => context.l10n.numberValue(value);
  @override
  String workspaceLabel(int workspace) =>
      context.l10n.workspaceLabel(workspace);
  @override
  String get batteryTitle => context.l10n.batteryTitle;
  @override
  String get volumeTitle => context.l10n.commonVolume;
  @override
  String get wifiTitle => context.l10n.commonWifi;
  @override
  String get notConnected => context.l10n.commonNotConnected;
  @override
  String get openDashboard => context.l10n.settingsShortcutActionOpenDashboard;
  @override
  String get percentSign => context.l10n.percentSign;
  @override
  String get celsiusUnit => context.l10n.celsiusUnit;
  @override
  String get metricCpu => context.l10n.metricCpu;
  @override
  String get mediaControls => context.l10n.mediaControls;
  @override
  String get mediaNowPlaying => context.l10n.mediaNowPlaying;
  @override
  String get mediaPrevious => context.l10n.mediaPrevious;
  @override
  String get mediaNext => context.l10n.mediaNext;
  @override
  String get mediaPlay => context.l10n.mediaPlay;
  @override
  String get mediaPause => context.l10n.mediaPause;
  @override
  String get workspaceOccupied => context.l10n.workspaceOccupied;
  @override
  String get workspaceEmpty => context.l10n.workspaceEmpty;
  @override
  String get workspaceActive => context.l10n.workspaceActive;
}
