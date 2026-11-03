import 'dart:collection';

import '../models/desktop_notification.dart';
import 'desktop_notifications_state.dart';

/// Applies native events without copying collections that the event leaves
/// untouched. Changed collections are owned by the resulting immutable state.
final class DesktopNotificationReducer {
  static const maxActiveNotifications = 256;
  static const maxBannerQueue = 24;

  int _nextSequence = 1;

  ({DesktopNotificationsState state, int? evictedId}) apply(
    DesktopNotificationsState state,
    DesktopNotificationEvent event,
  ) {
    var active = state.active;
    var history = state.history;
    var banners = state.bannerQueue;
    var pending = state.pendingDismissals;
    int? evictedId;

    if (event.kind == DesktopNotificationEventKind.closed) {
      final id = event.notificationId;
      if (active.containsKey(id)) {
        active = UnmodifiableMapView({...active}..remove(id));
      }
      banners = _removeBanner(banners, id);
      pending = _removePending(pending, id);
      history = _removeHistory(history, id);
    } else {
      final notification = event.notification!;
      final id = notification.id;
      final updatedActive = Map<int, DesktopNotification>.of(active);
      if (!active.containsKey(id) && active.length >= maxActiveNotifications) {
        evictedId = active.keys.first;
        updatedActive.remove(evictedId);
        banners = _removeBanner(banners, evictedId);
        pending = _removePending(pending, evictedId);
        history = _removeHistory(history, evictedId);
      }
      updatedActive[id] = notification;
      active = UnmodifiableMapView(updatedActive);
      pending = _removePending(pending, id);

      // A quiet update leaves a showing banner in place, with the new content.
      // An alert takes over its group's banner: one banner per group.
      final showBanner =
          !notification.historyOnly &&
          (!state.doNotDisturb ||
              notification.urgency == DesktopNotificationUrgency.critical);
      if (!showBanner) {
        banners = _removeBanner(banners, id);
      } else if (notification.alert) {
        final group = notification.groupingKey;
        bool sameGroup(int other) =>
            other != id && active[other]?.groupingKey == group;
        final index = banners.indexOf(id);
        if (index != 0 ||
            banners.length > maxBannerQueue ||
            banners.any(sameGroup)) {
          final updated = List<int>.of(banners)
            ..removeWhere((other) => other == id || sameGroup(other));
          updated.insert(0, id);
          if (updated.length > maxBannerQueue) updated.length = maxBannerQueue;
          banners = UnmodifiableListView(updated);
        }
      }

      final index = history.indexWhere(
        (record) => record.notification.id == id,
      );
      if (notification.transient && !notification.historyOnly) {
        history = _removeHistory(history, id);
      } else if (index >= 0) {
        final record = history[index];
        final unread = record.unread || notification.alert;
        if (!identical(record.notification, notification) ||
            record.unread != unread) {
          history = UnmodifiableListView(
            List.of(history)
              ..[index] = record.copyWith(
                notification: notification,
                unread: unread,
              ),
          );
        }
      } else {
        // History follows the active set, so its bound is the active bound.
        history = UnmodifiableListView(
          List<DesktopNotificationRecord>.of(history)..insert(
            0,
            DesktopNotificationRecord(
              notification: notification,
              sequence: _nextSequence++,
              unread: true,
            ),
          ),
        );
      }
    }

    return (
      state: state.copyWith(
        active: active,
        history: history,
        bannerQueue: banners,
        pendingDismissals: pending,
        lastEvent: event,
      ),
      evictedId: evictedId,
    );
  }

  List<int> _removeBanner(List<int> banners, int id) {
    final index = banners.indexOf(id);
    return index < 0
        ? banners
        : UnmodifiableListView(List.of(banners)..removeAt(index));
  }

  List<DesktopNotificationRecord> _removeHistory(
    List<DesktopNotificationRecord> history,
    int id,
  ) {
    final index = history.indexWhere((record) => record.notification.id == id);
    return index < 0
        ? history
        : UnmodifiableListView(List.of(history)..removeAt(index));
  }

  Set<int> _removePending(Set<int> pending, int id) => pending.contains(id)
      ? UnmodifiableSetView({...pending}..remove(id))
      : pending;
}
