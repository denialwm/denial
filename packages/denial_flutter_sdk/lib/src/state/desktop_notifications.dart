import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/desktop_notification.dart';
import '../models/notification_policy.dart';
import '../platform/denial_bridge_provider.dart';
import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import 'desktop_notification_reducer.dart';
import 'desktop_notifications_state.dart';
import 'notifier_lifecycle.dart';

export 'desktop_notifications_state.dart';

final desktopNotificationLoggerProvider = Provider<void Function(String)?>(
  (ref) => null,
);

final desktopNotificationsProvider =
    NotifierProvider<DesktopNotificationsController, DesktopNotificationsState>(
      DesktopNotificationsController.new,
    );

class DesktopNotificationsController extends Notifier<DesktopNotificationsState>
    with NotifierLifecycle<DesktopNotificationsState> {
  @override
  DesktopNotificationsState build() {
    final bridge = ref.watch(denialBridgeProvider);
    _dismiss = bridge.dismissNotification;
    _invokeAction = bridge.invokeNotificationAction;
    _invokeDefaultAction = bridge.invokeDefaultNotificationAction;
    _lightDisplay = bridge.requestDisplayOn;
    _logger = ref.watch(desktopNotificationLoggerProvider);
    _invokedActions.clear();
    _reducer = DesktopNotificationReducer();
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    final subscription = bridge.notificationEvents.listen(
      (event) => _handleEvent(event, generation),
    );
    cancelOnDispose(subscription);
    // The policy lives in Denial's settings, which other programs edit too.
    ref.listen<ShellNotificationSettings>(
      shellSettingsProvider.select((settings) => settings.notifications),
      (_, policy) => _applyPolicy(policy),
    );
    final policy = ref.read(shellSettingsProvider).notifications;
    return DesktopNotificationsState(
      doNotDisturb: policy.doNotDisturb,
      lockPreview: policy.lockPreview,
    );
  }

  static const int maxActiveNotifications =
      DesktopNotificationReducer.maxActiveNotifications;
  static const int maxBannerQueue = DesktopNotificationReducer.maxBannerQueue;

  late void Function(String message)? _logger;
  late bool Function(int notificationId) _dismiss;
  late bool Function(int notificationId, String actionKey) _invokeAction;
  late bool Function(int notificationId) _invokeDefaultAction;
  late void Function() _lightDisplay;
  late int _buildGeneration;

  final Map<int, Set<String>> _invokedActions = <int, Set<String>>{};
  late DesktopNotificationReducer _reducer;

  /// A notification the user can't clear only leaves its banner.
  bool dismiss(int notificationId) {
    final notification = state.active[notificationId];
    if (notification == null ||
        state.pendingDismissals.contains(notificationId)) {
      return false;
    }
    if (!notification.clearable) {
      hideBanner(notificationId);
      return true;
    }
    final summaries = _summariesLeftBy(notificationId);
    if (!_dismiss(notificationId)) {
      return false;
    }
    _markDismissalPending(notificationId);
    summaries.forEach(dismiss);
    return true;
  }

  bool dismissFromHistory(int notificationId) {
    if (state.active[notificationId]?.clearable == false) return false;
    final summaries = _summariesLeftBy(notificationId);
    final active = state.active.containsKey(notificationId);
    if (active &&
        !state.pendingDismissals.contains(notificationId) &&
        !_dismiss(notificationId)) {
      return false;
    }

    final pending = Set<int>.of(state.pendingDismissals);
    if (active) {
      pending.add(notificationId);
    }
    state = state.copyWith(
      history: List<DesktopNotificationRecord>.unmodifiable(
        state.history.where(
          (record) => record.notification.id != notificationId,
        ),
      ),
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where((id) => id != notificationId),
      ),
      pendingDismissals: Set<int>.unmodifiable(pending),
    );
    summaries.forEach(dismissFromHistory);
    return true;
  }

  /// A group's summary leaves with the group's last member.
  List<int> _summariesLeftBy(int notificationId) {
    final notification = state.active[notificationId];
    if (notification == null ||
        notification.groupSummary ||
        notification.groupKey.isEmpty) {
      return const [];
    }
    final rest = state.active.values.where(
      (other) =>
          other.id != notificationId &&
          other.groupKey == notification.groupKey &&
          !state.pendingDismissals.contains(other.id),
    );
    if (rest.any((other) => !other.groupSummary)) return const [];
    return [
      for (final summary in rest)
        if (summary.clearable) summary.id,
    ];
  }

  /// Dismisses what the user can clear of a group; true if anything left.
  bool dismissGroupFromHistory(String groupKey) {
    final group = state.groups
        .where((candidate) => candidate.key == groupKey)
        .firstOrNull;
    if (group == null) return false;
    var dismissed = false;
    for (final record in group.records) {
      if (record.notification.clearable &&
          dismissFromHistory(record.notification.id)) {
        dismissed = true;
      }
    }
    return dismissed;
  }

  void clearAll() {
    final pending = Set<int>.of(state.pendingDismissals);
    // Kept: dismissals that failed and notifications the user can't clear.
    final failed = <int>{};
    for (final MapEntry(key: id, value: notification) in state.active.entries) {
      if (pending.contains(id)) {
        continue;
      }
      if (!notification.clearable) {
        failed.add(id);
        continue;
      }
      if (_dismiss(id)) {
        pending.add(id);
      } else {
        failed.add(id);
      }
    }

    state = state.copyWith(
      history: List<DesktopNotificationRecord>.unmodifiable(
        state.history.where(
          (record) => failed.contains(record.notification.id),
        ),
      ),
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where(failed.contains),
      ),
      pendingDismissals: Set<int>.unmodifiable(pending),
    );
  }

  bool invokeAction(int notificationId, String actionKey) {
    final notification = state.active[notificationId];
    if (notification == null ||
        !notification.actions.any((action) => action.key == actionKey)) {
      return false;
    }
    return _invokeOnce(
      notificationId,
      actionKey,
      () => _invokeAction(notificationId, actionKey),
    );
  }

  bool invokeDefaultAction(int notificationId) {
    final notification = state.active[notificationId];
    if (notification == null ||
        !notification.actions.any((action) => action.key == 'default')) {
      return false;
    }
    return _invokeOnce(
      notificationId,
      'default',
      () => _invokeDefaultAction(notificationId),
    );
  }

  void setDoNotDisturb(bool enabled) {
    ref.read(shellSettingsProvider.notifier).setDoNotDisturb(enabled);
  }

  void toggleDoNotDisturb() => setDoNotDisturb(!state.doNotDisturb);

  void setLockPreview(NotificationPreviewMode mode) {
    ref.read(shellSettingsProvider.notifier).setLockPreview(mode);
  }

  void _applyPolicy(ShellNotificationSettings policy) {
    final queue = policy.doNotDisturb && !state.doNotDisturb
        ? state.bannerQueue.where((id) {
            final notification = state.active[id];
            return notification != null &&
                notification.urgency == DesktopNotificationUrgency.critical;
          })
        : state.bannerQueue;
    state = state.copyWith(
      doNotDisturb: policy.doNotDisturb,
      lockPreview: policy.lockPreview,
      bannerQueue: List<int>.unmodifiable(queue),
    );
  }

  void markAllRead() {
    if (state.unreadCount == 0) {
      return;
    }
    state = state.copyWith(
      history: List<DesktopNotificationRecord>.unmodifiable(
        state.history.map((record) => record.copyWith(unread: false)),
      ),
    );
  }

  /// Stops a heads-up presentation without closing the notification or
  /// acknowledging its history entry.
  void hideBanner(int notificationId) {
    if (!state.bannerQueue.contains(notificationId)) return;
    state = state.copyWith(
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where((id) => id != notificationId),
      ),
    );
  }

  bool _invokeOnce(
    int notificationId,
    String actionKey,
    bool Function() invoke,
  ) {
    final invoked = _invokedActions.putIfAbsent(
      notificationId,
      () => <String>{},
    );
    if (!invoked.add(actionKey)) {
      return false;
    }
    if (invoke()) {
      return true;
    }
    invoked.remove(actionKey);
    if (invoked.isEmpty) {
      _invokedActions.remove(notificationId);
    }
    return false;
  }

  void _markDismissalPending(int notificationId) {
    final pending = Set<int>.of(state.pendingDismissals)..add(notificationId);
    state = state.copyWith(
      pendingDismissals: Set<int>.unmodifiable(pending),
      bannerQueue: List<int>.unmodifiable(
        state.bannerQueue.where((id) => id != notificationId),
      ),
    );
  }

  void _handleEvent(DesktopNotificationEvent event, int generation) {
    if (!isBuildGenerationActive(generation)) {
      return;
    }
    final result = _reducer.apply(state, event);
    final id = event.kind == DesktopNotificationEventKind.closed
        ? event.notificationId
        : event.notification!.id;
    _invokedActions.remove(id);
    if (result.evictedId case final evictedId?) {
      _invokedActions.remove(evictedId);
    }
    state = result.state;
    _logger?.call(event.toReadableString());
    _wakeFor(event);
  }

  /// A notification that pops up turns the screen on, when the settings
  /// ask for it; Do not disturb keeps it dark.
  void _wakeFor(DesktopNotificationEvent event) {
    final notification = event.notification;
    if (event.kind == DesktopNotificationEventKind.closed ||
        notification == null ||
        !notification.alert ||
        notification.historyOnly ||
        !state.bannerQueue.contains(notification.id) ||
        !ref.read(shellSettingsProvider).notifications.wakeScreen) {
      return;
    }
    _lightDisplay();
  }
}
