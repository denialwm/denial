import 'dart:typed_data';

import 'package:denial_sdk/system.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'system_services.dart' show WifiNetwork;

/// Public read-only workspace projection, without desktop-controller exposure.
class WorkspaceStatus {
  WorkspaceStatus({
    required this.count,
    required this.active,
    required Set<int> occupied,
  }) : occupied = Set.unmodifiable(occupied);

  final int count;
  final int active;
  final Set<int> occupied;
}

/// A user application window, without native surfaces or controller access.
class ApplicationWindow {
  const ApplicationWindow({
    required this.id,
    required this.appId,
    required this.title,
    required this.active,
    required this.minimized,
    this.tiled = false,
    this.previewSize = Size.zero,
  });
  final int id;
  final String appId;
  final String title;
  final bool active;
  final bool minimized;

  /// The desktop layout manages this window as a tile.
  final bool tiled;

  /// Logical bounds of the content rendered by [ShellWindowServices.buildWindowPreview].
  /// Zero means the window has not supplied usable dimensions yet.
  final Size previewSize;
}

/// A catalog entry that can be retained by panels even when no window exists.
/// [id] is the opaque, persistent launch identity; [appId] is used for icons.
class LaunchableApplication {
  const LaunchableApplication({
    required this.id,
    required this.appId,
    required this.name,
    required this.windowAppIds,
  });
  final String id;
  final String appId;
  final String name;
  final List<String> windowAppIds;
}

abstract interface class MediaCommands {
  MprisPlaybackState get current;
  Future<void> previous();
  Future<void> playPause();
  Future<void> next();
}

/// Window projections and presentation actions supplied by the host.
abstract interface class ShellWindowServices {
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId);
  void activateWindow(int id);

  /// Minimizes through the compositor, including removal from the tile layout.
  void minimizeWindow(int id);

  /// Live client content, fitted without resizing the window or forwarding input.
  /// Unavailable content uses an icon; the host owns the underlying textures.
  Widget buildWindowPreview(BuildContext context, int windowId);

  /// Temporarily fades other windows on the monitor's current workspace.
  /// Does not activate, raise or restore the target. Release on hover exit,
  /// dismissal and disposal; releasing an old request cannot cancel a newer one.
  VoidCallback emphasizeWindow(int windowId, {required int monitorId});
}

/// Catalog identities, application icons and native-backed launching.
abstract interface class ShellApplicationServices {
  ProviderListenable<List<LaunchableApplication>> get applications;

  /// False means unavailable or rejected. Never execute persisted command lines.
  Future<bool> launchApplication(String id, {int? monitorId});
  Widget buildApplicationIcon(BuildContext context, String appId);
}

/// Host-owned desktop presentation and navigation.
abstract interface class ShellDesktopServices {
  /// Reveals the desktop across outputs while preserving native window state.
  void toggleDesktop();
  ProviderListenable<bool> get desktopVisible;
  void toggleLauncher();

  /// Opens the host's dashboard, including from touch-only desktop controls.
  void openDashboard();
  void toggleDashboard();
  void openPowerSettings();
}

/// Output geometry and workspace projections/actions.
abstract interface class ShellWorkspaceServices {
  /// Logical bounds in the shell scene's coordinate space.
  ProviderListenable<Rect?> monitorBounds(int monitorId);
  ProviderListenable<bool> get workspacesEnabled;
  ProviderListenable<WorkspaceStatus> workspace(int monitorId);
  void switchWorkspace({required int monitorId, required int workspaceId});
}

/// Read-only system status. Providers retain their host-owned lifetimes.
abstract interface class ShellTelemetryServices {
  ProviderListenable<BatteryStatus> get battery;
  ProviderListenable<LoadSeries> get cpu;
  ProviderListenable<List<GpuLoad>> get gpus;
  ProviderListenable<AsyncValue<DateTime>> get clock;
}

/// Output volume shares the host's state and interaction reconciliation.
abstract interface class ShellAudioServices {
  /// The output volume, 0 while [volumeAvailable] is false.
  ProviderListenable<double> get volume;

  /// Whether an audio service has reported the volume. Until it has, show the
  /// volume as unavailable: interactions are ignored.
  ProviderListenable<bool> get volumeAvailable;
  void beginVolumeInteraction();
  void setVolume(double value);
  void commitVolume(double value);
}

/// The connected Wi-Fi network, including its current signal strength.
abstract interface class ShellConnectivityServices {
  ProviderListenable<WifiNetwork?> get connectedWifi;
}

/// Media playback state and semantic controls.
abstract interface class ShellMediaServices {
  ProviderListenable<AsyncValue<MprisPlaybackState>> get media;
  ProviderListenable<MediaCommands> get mediaCommands;
}

/// Shared visual resources and locale-dependent labels.
abstract interface class ShellPresentationServices {
  ProviderListenable<Color> get accent;
  ProviderListenable<AsyncValue<Uint8List?>> imageBytes(String path);
  MouseCursor get normalCursor;
  MouseCursor get linkCursor;
  ShellStrings strings(BuildContext context);
}

/// StatusNotifier identities and the host's menu/input renderer.
abstract interface class ShellTrayServices {
  ProviderListenable<bool> get trayVisible;
  ProviderListenable<List<String>> get trayItemIds;

  /// Null renders all items; a subset renders these IDs in order, ignoring
  /// removed IDs. Native activation and menu ownership remain host-side.
  Widget buildSystemTray(
    BuildContext context, {
    required bool horizontal,
    bool wrap = false,
    Color? foregroundColor,
    List<String>? itemIds,
  });
}

/// The complete host bundle supplied to composed surfaces and actions.
/// Feature widgets/helpers should request the focused capability they need.
/// Existing plugin calls remain available through this aggregate interface.
abstract interface class ShellServices
    implements
        ShellWindowServices,
        ShellApplicationServices,
        ShellDesktopServices,
        ShellWorkspaceServices,
        ShellTelemetryServices,
        ShellAudioServices,
        ShellConnectivityServices,
        ShellMediaServices,
        ShellPresentationServices,
        ShellTrayServices {}

/// Localized platform labels/formatters; implementations depend on the locale.
abstract interface class ShellStrings {
  String time(DateTime value);
  String shortDate(DateTime value);
  String batteryLine(String state, int capacity);
  String numberValue(int value);
  String workspaceLabel(int workspace);
  String get batteryTitle;
  String get volumeTitle;
  String get wifiTitle;
  String get notConnected;
  String get openDashboard;
  String get percentSign;
  String get celsiusUnit;
  String get metricCpu;
  String get mediaControls;
  String get mediaNowPlaying;
  String get mediaPrevious;
  String get mediaNext;
  String get mediaPlay;
  String get mediaPause;
  String get workspaceOccupied;
  String get workspaceEmpty;
  String get workspaceActive;
}

/// Makes explicitly supplied services available below one composed component.
class ShellServicesScope extends InheritedWidget {
  const ShellServicesScope({
    required this.services,
    required super.child,
    super.key,
  });
  final ShellServices services;

  static ShellServices of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    if (scope == null) throw StateError('ShellServicesScope is missing.');
    return scope.services;
  }

  @override
  bool updateShouldNotify(ShellServicesScope oldWidget) =>
      !identical(services, oldWidget.services);
}
