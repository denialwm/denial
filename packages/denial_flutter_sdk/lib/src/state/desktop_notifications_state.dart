import 'package:meta/meta.dart';

import '../models/desktop_notification.dart';
import '../models/notification_policy.dart';

/// One notification in history. History holds exactly the notifications
/// deniald still has; a closed one leaves it.
@immutable
class DesktopNotificationRecord {
  const DesktopNotificationRecord({
    required this.notification,
    required this.sequence,
    required this.unread,
  });

  final DesktopNotification notification;
  final int sequence;
  final bool unread;

  DesktopNotificationRecord copyWith({
    DesktopNotification? notification,
    bool? unread,
  }) {
    return DesktopNotificationRecord(
      notification: notification ?? this.notification,
      sequence: sequence,
      unread: unread ?? this.unread,
    );
  }
}

/// Notifications that belong together, as history shows them. deniald keeps
/// group keys inside one app; without a sender group, the app is the group.
@immutable
class DesktopNotificationGroup {
  const DesktopNotificationGroup({
    required this.key,
    required this.members,
    this.summary,
  });

  final String key;

  /// Newest first. A group the sender only summarized shows its summary.
  final List<DesktopNotificationRecord> members;

  /// The sender's own stand-in for the group, when it posted one.
  final DesktopNotificationRecord? summary;

  /// Two or more members stack into one card.
  bool get stacked => members.length >= 2;

  DesktopNotificationRecord get newest => members.first;

  bool get unread => members.any((record) => record.unread);

  /// Whether a swipe or Clear all can remove anything from it.
  bool get clearable =>
      members.any((record) => record.notification.clearable) ||
      (summary?.notification.clearable ?? false);

  /// Every notification of the group, summary included.
  Iterable<DesktopNotificationRecord> get records sync* {
    yield* members;
    final summary = this.summary;
    if (summary != null && !members.contains(summary)) yield summary;
  }
}

@immutable
class DesktopNotificationsState {
  const DesktopNotificationsState({
    this.active = const <int, DesktopNotification>{},
    this.history = const <DesktopNotificationRecord>[],
    this.bannerQueue = const <int>[],
    this.pendingDismissals = const <int>{},
    this.doNotDisturb = false,
    this.lockPreview = NotificationPreviewMode.full,
    this.lastEvent,
  });

  static const int maxVisibleBanners = 3;
  static const bool criticalBypassesDoNotDisturb = true;

  final Map<int, DesktopNotification> active;
  final List<DesktopNotificationRecord> history;
  final List<int> bannerQueue;
  final Set<int> pendingDismissals;
  final bool doNotDisturb;
  final NotificationPreviewMode lockPreview;
  final DesktopNotificationEvent? lastEvent;

  List<DesktopNotification> get bannerNotifications {
    final visible = <DesktopNotification>[];
    for (final id in bannerQueue) {
      final notification = active[id];
      if (notification == null ||
          notification.historyOnly ||
          pendingDismissals.contains(id)) {
        continue;
      }
      if (doNotDisturb &&
          !(criticalBypassesDoNotDisturb &&
              notification.urgency == DesktopNotificationUrgency.critical)) {
        continue;
      }
      visible.add(notification);
      if (visible.length == maxVisibleBanners) {
        break;
      }
    }
    return List<DesktopNotification>.unmodifiable(visible);
  }

  DesktopNotification? get bannerNotification {
    final notifications = bannerNotifications;
    return notifications.isEmpty ? null : notifications.first;
  }

  /// History as groups, newest first; derived once per history.
  List<DesktopNotificationGroup> get groups =>
      _groups[history] ??= _groupHistory(history);

  int get unreadCount {
    var count = 0;
    for (final record in history) {
      if (record.unread) {
        count += 1;
      }
    }
    return count;
  }

  static final _groups = Expando<List<DesktopNotificationGroup>>();

  static List<DesktopNotificationGroup> _groupHistory(
    List<DesktopNotificationRecord> history,
  ) {
    final members = <String, List<DesktopNotificationRecord>>{};
    final summaries = <String, List<DesktopNotificationRecord>>{};
    for (final record in history) {
      final notification = record.notification;
      final key = notification.groupingKey;
      members.putIfAbsent(key, () => []);
      summaries.putIfAbsent(key, () => []);
      if (notification.groupSummary) {
        summaries[key]!.add(record);
      } else {
        members[key]!.add(record);
      }
    }
    return List<DesktopNotificationGroup>.unmodifiable([
      for (final MapEntry(:key, value: records) in members.entries)
        DesktopNotificationGroup(
          key: key,
          members: List<DesktopNotificationRecord>.unmodifiable(
            records.isEmpty ? summaries[key]! : records,
          ),
          summary: summaries[key]!.firstOrNull,
        ),
    ]);
  }

  DesktopNotificationsState copyWith({
    Map<int, DesktopNotification>? active,
    List<DesktopNotificationRecord>? history,
    List<int>? bannerQueue,
    Set<int>? pendingDismissals,
    bool? doNotDisturb,
    NotificationPreviewMode? lockPreview,
    DesktopNotificationEvent? lastEvent,
  }) {
    return DesktopNotificationsState(
      active: active ?? this.active,
      history: history ?? this.history,
      bannerQueue: bannerQueue ?? this.bannerQueue,
      pendingDismissals: pendingDismissals ?? this.pendingDismissals,
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      lockPreview: lockPreview ?? this.lockPreview,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}
