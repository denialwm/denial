// Previous event reducer retained for differential tests and AOT benchmarks.
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';

class LegacyNotificationReducer {
  static const maxActiveNotifications = 256;
  static const maxBannerQueue = 24;
  int _nextSequence = 1;

  ({DesktopNotificationsState state, int? evictedId}) apply(
    DesktopNotificationsState state,
    DesktopNotificationEvent event,
  ) {
    int? evictedId;
    final active = Map<int, DesktopNotification>.of(state.active);
    final history = List<DesktopNotificationRecord>.of(state.history);
    final bannerQueue = List<int>.of(state.bannerQueue);
    final pending = Set<int>.of(state.pendingDismissals);

    if (event.kind == DesktopNotificationEventKind.closed) {
      active.remove(event.notificationId);
      bannerQueue.remove(event.notificationId);
      pending.remove(event.notificationId);
      history.removeWhere(
        (record) => record.notification.id == event.notificationId,
      );
    } else {
      final notification = event.notification!;
      if (!active.containsKey(notification.id) &&
          active.length >= maxActiveNotifications) {
        evictedId = active.keys.first;
        active.remove(evictedId);
        bannerQueue.remove(evictedId);
        pending.remove(evictedId);
        history.removeWhere((record) => record.notification.id == evictedId);
      }
      active[notification.id] = notification;
      pending.remove(notification.id);

      bannerQueue.remove(notification.id);
      if (!notification.historyOnly &&
          (!state.doNotDisturb ||
              notification.urgency == DesktopNotificationUrgency.critical)) {
        bannerQueue.insert(0, notification.id);
      }
      if (bannerQueue.length > maxBannerQueue) {
        bannerQueue.removeRange(maxBannerQueue, bannerQueue.length);
      }

      final historyIndex = history.indexWhere(
        (record) => record.notification.id == notification.id,
      );
      if (notification.transient && !notification.historyOnly) {
        if (historyIndex >= 0) {
          history.removeAt(historyIndex);
        }
      } else if (historyIndex >= 0) {
        history[historyIndex] = history[historyIndex].copyWith(
          notification: notification,
          unread: true,
        );
      } else {
        history.insert(
          0,
          DesktopNotificationRecord(
            notification: notification,
            sequence: _nextSequence++,
            unread: true,
          ),
        );
      }
    }

    state = DesktopNotificationsState(
      active: Map<int, DesktopNotification>.unmodifiable(active),
      history: List<DesktopNotificationRecord>.unmodifiable(history),
      bannerQueue: List<int>.unmodifiable(bannerQueue),
      pendingDismissals: Set<int>.unmodifiable(pending),
      doNotDisturb: state.doNotDisturb,
      lockPreview: state.lockPreview,
      lastEvent: event,
    );
    return (state: state, evictedId: evictedId);
  }
}
