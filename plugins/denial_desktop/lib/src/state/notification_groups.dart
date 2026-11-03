import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/state.dart';

/// Stacked notification groups the user opened, by group key. The shade and
/// the notification center share it; a group that stops stacking folds.
final expandedNotificationGroupsProvider =
    NotifierProvider<ExpandedNotificationGroups, Set<String>>(
      ExpandedNotificationGroups.new,
    );

class ExpandedNotificationGroups extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.listen(desktopNotificationsProvider.select((state) => state.groups), (
      _,
      groups,
    ) {
      final stacked = {
        for (final group in groups)
          if (group.stacked) group.key,
      };
      if (!state.every(stacked.contains)) {
        state = Set.unmodifiable(state.where(stacked.contains));
      }
    });
    return const {};
  }

  void expand(String groupKey) =>
      state = Set.unmodifiable({...state, groupKey});

  void collapse(String groupKey) =>
      state = Set.unmodifiable({...state}..remove(groupKey));
}

/// The group a lock-screen tap asked to open once the session unlocks.
final lockNotificationOpenProvider =
    NotifierProvider<LockNotificationOpen, String?>(LockNotificationOpen.new);

class LockNotificationOpen extends Notifier<String?> {
  @override
  String? build() => null;

  void request(String groupKey) => state = groupKey;

  void clear() => state = null;
}
