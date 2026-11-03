import 'package:denial_flutter_sdk/state.dart';

/// One row of notification history: a notification, a stacked group, or the
/// header above an opened group's members.
sealed class NotificationHistoryRow {
  const NotificationHistoryRow();

  /// Stable across rebuilds, for the row's widget key.
  Object get key;
}

final class NotificationRow extends NotificationHistoryRow {
  const NotificationRow(this.record);

  final DesktopNotificationRecord record;

  @override
  Object get key => record.notification.id;
}

final class NotificationGroupRow extends NotificationHistoryRow {
  const NotificationGroupRow(this.group);

  final DesktopNotificationGroup group;

  @override
  Object get key => 'group\u0000${group.key}';
}

final class NotificationGroupHeaderRow extends NotificationHistoryRow {
  const NotificationGroupHeaderRow(this.group);

  final DesktopNotificationGroup group;

  @override
  Object get key => 'header\u0000${group.key}';
}

/// History rows, newest first. A stacked group shows as one card unless its
/// key is in [expanded].
List<NotificationHistoryRow> notificationHistoryRows(
  List<DesktopNotificationGroup> groups,
  Set<String> expanded,
) {
  return [
    for (final group in groups)
      if (!group.stacked)
        NotificationRow(group.newest)
      else if (!expanded.contains(group.key))
        NotificationGroupRow(group)
      else ...[
        NotificationGroupHeaderRow(group),
        for (final record in group.members) NotificationRow(record),
      ],
  ];
}
