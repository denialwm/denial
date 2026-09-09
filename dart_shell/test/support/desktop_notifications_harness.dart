import 'dart:async';

import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/models/battery_status.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_snapshot.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:denial_dart_shell/src/state/desktop_notifications.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/network_connectivity.dart';
import 'package:denial_dart_shell/src/state/quick_settings.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopNotificationsTestHarness {
  DesktopNotificationsTestHarness({
    NotificationPolicyStore? policyStore,
    void Function(String message)? logger,
  }) {
    bridge = TestNotificationBridge();
    container = ProviderContainer.test(
      overrides: [
        denialBridgeProvider.overrideWithValue(bridge),
        clockProvider.overrideWith((_) => Stream.value(DateTime(2026, 9, 9))),
        batteryProvider.overrideWithBuild((_, _) => BatteryStatus.unknown),
        networkConnectivityProvider.overrideWithBuild(
          (_, _) => NetworkConnectivityState.initial(),
        ),
        quickSettingsProvider.overrideWithBuild(
          (_, _) => QuickSettingsState.initial(),
        ),
        notificationPolicyStoreProvider.overrideWithValue(policyStore),
        desktopNotificationLoggerProvider.overrideWithValue(logger ?? logs.add),
      ],
    );
    controller = container.read(desktopNotificationsProvider.notifier);
  }

  late final TestNotificationBridge bridge;
  late final ProviderContainer container;
  late final DesktopNotificationsController controller;
  final List<String> logs = <String>[];

  DesktopNotificationsState get state =>
      container.read(desktopNotificationsProvider);

  List<int> get dismissed => bridge.dismissed;
  List<(int, String)> get invoked => bridge.invoked;
  List<int> get defaultInvoked => bridge.defaultInvoked;

  void add(DesktopNotificationEvent event) => bridge.add(event);

  Future<void> dispose() => bridge.close();
}

class TestNotificationBridge extends DenialBridge {
  @override
  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) async =>
      DenialWindowSnapshot(sequence: 0, windows: fallback);

  @override
  Future<DisplayLayout?> getDisplayLayout() async => null;

  final StreamController<DesktopNotificationEvent> _events =
      StreamController<DesktopNotificationEvent>.broadcast(sync: true);

  final List<int> dismissed = <int>[];
  final List<(int, String)> invoked = <(int, String)>[];
  final List<int> defaultInvoked = <int>[];

  @override
  Stream<DesktopNotificationEvent> get notificationEvents => _events.stream;

  void add(DesktopNotificationEvent event) => _events.add(event);

  @override
  bool dismissNotification(int notificationId) {
    dismissed.add(notificationId);
    return true;
  }

  @override
  bool invokeNotificationAction(int notificationId, String actionKey) {
    invoked.add((notificationId, actionKey));
    return true;
  }

  @override
  bool invokeDefaultNotificationAction(int notificationId) {
    defaultInvoked.add(notificationId);
    return true;
  }

  Future<void> close() async {
    await _events.close();
    dispose();
  }
}
