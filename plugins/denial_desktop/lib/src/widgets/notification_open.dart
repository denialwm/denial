import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/models.dart' show DenialWindow;
import 'package:denial_flutter_sdk/state.dart';

import '../state/notification_groups.dart';
import '../state/reference_shell_controller.dart';

/// Opens what a notification belongs to. Its default action asks the app
/// itself; without one, the app its desktop entry names is focused or
/// started, and the notification closes as a default action would close it.
bool openNotification(WidgetRef ref, int notificationId) {
  final notifications = ref.read(desktopNotificationsProvider.notifier);
  final notification = ref
      .read(desktopNotificationsProvider)
      .active[notificationId];
  if (notification == null) return false;
  if (notification.actions.any((action) => action.key == 'default')) {
    return notifications.invokeDefaultAction(notificationId);
  }
  if (notification.desktopEntry.isEmpty) return false;
  unawaited(
    _openApp(
      notification.desktopEntry,
      repository: ref.read(desktopAppsRepositoryProvider),
      launcher: ref.read(appLauncherProvider),
      shell: ref.read(referenceShellProvider.notifier),
      windows: ref.read(referenceShellProvider).allOpenAppWindows,
    ),
  );
  if (notification.resident) {
    notifications.hideBanner(notificationId);
  } else {
    notifications.dismiss(notificationId);
  }
  return true;
}

/// Opens what a lock-screen tap asked for, once the session is unlocked: a
/// stacked group opens the shade with the group expanded, anything else its
/// app.
void openLockNotification(WidgetRef ref) {
  final key = ref.read(lockNotificationOpenProvider);
  if (key == null) return;
  ref.read(lockNotificationOpenProvider.notifier).clear();
  final group = ref
      .read(desktopNotificationsProvider)
      .groups
      .where((candidate) => candidate.key == key)
      .firstOrNull;
  if (group == null) return;
  if (group.stacked) {
    ref.read(expandedNotificationGroupsProvider.notifier).expand(key);
    ref.read(referenceShellProvider.notifier).openNotificationShade();
  } else {
    openNotification(ref, group.newest.notification.id);
  }
}

Future<void> _openApp(
  String desktopEntry, {
  required DesktopAppsRepository repository,
  required AppLauncher launcher,
  required ReferenceShellController shell,
  required Iterable<DenialWindow> windows,
}) async {
  final app = await repository.loadApplication(desktopEntry);
  if (app == null) return;
  final running = launcher.findOpenWindow(app, windows);
  if (running != null) {
    shell.focusWindow(running);
  } else {
    await launcher.launch(app);
  }
}
