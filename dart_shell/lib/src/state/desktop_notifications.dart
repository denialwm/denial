import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/launcher_providers.dart';
import '../models/desktop_notification.dart';
import '../services/notification_policy_repository.dart';
import 'shell_controller.dart';

final notificationPolicyStoreProvider = Provider<NotificationPolicyStore>(
  (ref) => NotificationPolicyRepository(
    paths: ref.watch(runtimePathsProvider),
  ),
);

final desktopNotificationsProvider = StateNotifierProvider<
    DesktopNotificationsController, DesktopNotificationsState>((ref) {
  final bridge = ref.read(denialBridgeProvider);
  return DesktopNotificationsController(
    bridge.notificationEvents,
    dismiss: bridge.dismissNotification,
    invokeAction: bridge.invokeNotificationAction,
    invokeDefaultAction: bridge.invokeDefaultNotificationAction,
    policyStore: ref.watch(notificationPolicyStoreProvider),
  );
});

@immutable
class DesktopNotificationRecord {
  const DesktopNotificationRecord({
    required this.notification,
    required this.sequence,
    required this.active,
    required this.unread,
    this.closeReason = 0,
  });

  final DesktopNotification notification;
  final int sequence;
  final bool active;
  final bool unread;
  final int closeReason;

  DesktopNotificationRecord copyWith({
    DesktopNotification? notification,
    bool? active,
    bool? unread,
    int? closeReason,
  }) {
    return DesktopNotificationRecord(
      notification: notification ?? this.notification,
      sequence: sequence,
      active: active ?? this.active,
      unread: unread ?? this.unread,
      closeReason: closeReason ?? this.closeReason,
    );
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
    this.policyLoaded = true,
    this.lockPreview = NotificationPreviewMode.applicationOnly,
    this.lastEvent,
  });

  static const int maxVisibleBanners = 3;
  static const bool criticalBypassesDoNotDisturb = true;

  final Map<int, DesktopNotification> active;
  final List<DesktopNotificationRecord> history;
  final List<int> bannerQueue;
  final Set<int> pendingDismissals;
  final bool doNotDisturb;
  final bool policyLoaded;
  final NotificationPreviewMode lockPreview;
  final DesktopNotificationEvent? lastEvent;

  List<DesktopNotification> get bannerNotifications {
    final visible = <DesktopNotification>[];
    for (final id in bannerQueue) {
      final notification = active[id];
      if (notification == null || pendingDismissals.contains(id)) {
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

  int get unreadCount {
    var count = 0;
    for (final record in history) {
      if (record.unread) {
        count += 1;
      }
    }
    return count;
  }

  DesktopNotificationsState copyWith({
    Map<int, DesktopNotification>? active,
    List<DesktopNotificationRecord>? history,
    List<int>? bannerQueue,
    Set<int>? pendingDismissals,
    bool? doNotDisturb,
    bool? policyLoaded,
    NotificationPreviewMode? lockPreview,
    DesktopNotificationEvent? lastEvent,
  }) {
    return DesktopNotificationsState(
      active: active ?? this.active,
      history: history ?? this.history,
      bannerQueue: bannerQueue ?? this.bannerQueue,
      pendingDismissals: pendingDismissals ?? this.pendingDismissals,
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      policyLoaded: policyLoaded ?? this.policyLoaded,
      lockPreview: lockPreview ?? this.lockPreview,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}

class DesktopNotificationsController
    extends StateNotifier<DesktopNotificationsState> {
  DesktopNotificationsController(
    Stream<DesktopNotificationEvent> events, {
    required bool Function(int notificationId) dismiss,
    required bool Function(int notificationId, String actionKey) invokeAction,
    required bool Function(int notificationId) invokeDefaultAction,
    NotificationPolicyStore? policyStore,
    void Function(String message)? logger,
  })  : _dismiss = dismiss,
        _invokeAction = invokeAction,
        _invokeDefaultAction = invokeDefaultAction,
        _policyStore = policyStore,
        _logger = logger,
        super(DesktopNotificationsState(policyLoaded: policyStore == null)) {
    _subscription = events.listen(_handleEvent);
    if (policyStore != null) {
      unawaited(_loadPolicy());
    }
  }

  static const int maxActiveNotifications = 256;
  static const int maxHistoryEntries = 100;
  static const int maxBannerQueue = 24;

  final void Function(String message)? _logger;
  final bool Function(int notificationId) _dismiss;
  final bool Function(int notificationId, String actionKey) _invokeAction;
  final bool Function(int notificationId) _invokeDefaultAction;
  final NotificationPolicyStore? _policyStore;
  late final StreamSubscription<DesktopNotificationEvent> _subscription;

  final Map<int, Set<String>> _invokedActions = <int, Set<String>>{};
  int _nextSequence = 1;
  bool _policyMutated = false;
  bool _policyWriteRunning = false;
  NotificationPolicy? _pendingPolicyWrite;

  bool dismiss(int notificationId) {
    if (!state.active.containsKey(notificationId) ||
        state.pendingDismissals.contains(notificationId)) {
      return false;
    }
    if (!_dismiss(notificationId)) {
      return false;
    }
    _markDismissalPending(notificationId);
    return true;
  }

  bool dismissFromHistory(int notificationId) {
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
    return true;
  }

  void clearAll() {
    final pending = Set<int>.of(state.pendingDismissals);
    final failed = <int>{};
    for (final id in state.active.keys) {
      if (pending.contains(id)) {
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
          (record) => record.active && failed.contains(record.notification.id),
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
    if (state.doNotDisturb == enabled && state.policyLoaded) {
      return;
    }
    _policyMutated = true;
    final queue = enabled
        ? state.bannerQueue.where((id) {
            final notification = state.active[id];
            return notification != null &&
                notification.urgency == DesktopNotificationUrgency.critical;
          }).toList(growable: false)
        : state.bannerQueue;
    state = state.copyWith(
      doNotDisturb: enabled,
      policyLoaded: true,
      bannerQueue: List<int>.unmodifiable(queue),
    );
    _schedulePolicyWrite();
  }

  void toggleDoNotDisturb() => setDoNotDisturb(!state.doNotDisturb);

  void setLockPreview(NotificationPreviewMode mode) {
    if (state.lockPreview == mode && state.policyLoaded) {
      return;
    }
    _policyMutated = true;
    state = state.copyWith(lockPreview: mode, policyLoaded: true);
    _schedulePolicyWrite();
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

  bool _invokeOnce(
    int notificationId,
    String actionKey,
    bool Function() invoke,
  ) {
    final invoked =
        _invokedActions.putIfAbsent(notificationId, () => <String>{});
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

  void _handleEvent(DesktopNotificationEvent event) {
    final active = Map<int, DesktopNotification>.of(state.active);
    final history = List<DesktopNotificationRecord>.of(state.history);
    final bannerQueue = List<int>.of(state.bannerQueue);
    final pending = Set<int>.of(state.pendingDismissals);

    if (event.kind == DesktopNotificationEventKind.closed) {
      active.remove(event.notificationId);
      bannerQueue.remove(event.notificationId);
      pending.remove(event.notificationId);
      _invokedActions.remove(event.notificationId);
      final historyIndex = history.indexWhere(
        (record) => record.notification.id == event.notificationId,
      );
      if (historyIndex >= 0) {
        history[historyIndex] = history[historyIndex].copyWith(
          active: false,
          closeReason: event.closeReason,
        );
      }
    } else {
      final notification = event.notification!;
      if (!active.containsKey(notification.id) &&
          active.length >= maxActiveNotifications) {
        final evictedId = active.keys.first;
        active.remove(evictedId);
        bannerQueue.remove(evictedId);
        pending.remove(evictedId);
        _invokedActions.remove(evictedId);
      }
      active[notification.id] = notification;
      pending.remove(notification.id);
      _invokedActions.remove(notification.id);

      bannerQueue.remove(notification.id);
      if (!state.doNotDisturb ||
          notification.urgency == DesktopNotificationUrgency.critical) {
        bannerQueue.insert(0, notification.id);
      }
      if (bannerQueue.length > maxBannerQueue) {
        bannerQueue.removeRange(maxBannerQueue, bannerQueue.length);
      }

      final historyIndex = history.indexWhere(
        (record) => record.notification.id == notification.id,
      );
      if (notification.transient) {
        if (historyIndex >= 0) {
          history.removeAt(historyIndex);
        }
      } else if (historyIndex >= 0) {
        history[historyIndex] = history[historyIndex].copyWith(
          notification: notification,
          active: true,
          unread: true,
          closeReason: 0,
        );
      } else {
        history.insert(
          0,
          DesktopNotificationRecord(
            notification: notification,
            sequence: _nextSequence++,
            active: true,
            unread: true,
          ),
        );
      }
      if (history.length > maxHistoryEntries) {
        history.removeRange(maxHistoryEntries, history.length);
      }
    }

    state = DesktopNotificationsState(
      active: Map<int, DesktopNotification>.unmodifiable(active),
      history: List<DesktopNotificationRecord>.unmodifiable(history),
      bannerQueue: List<int>.unmodifiable(bannerQueue),
      pendingDismissals: Set<int>.unmodifiable(pending),
      doNotDisturb: state.doNotDisturb,
      policyLoaded: state.policyLoaded,
      lockPreview: state.lockPreview,
      lastEvent: event,
    );
    _logger?.call(event.toReadableString());
  }

  Future<void> _loadPolicy() async {
    final policy = await _policyStore!.read();
    if (!mounted) {
      return;
    }
    if (_policyMutated) {
      state = state.copyWith(policyLoaded: true);
      return;
    }
    state = state.copyWith(
      doNotDisturb: policy.doNotDisturb,
      lockPreview: policy.lockPreview,
      policyLoaded: true,
    );
  }

  void _schedulePolicyWrite() {
    if (_policyStore == null) {
      return;
    }
    _pendingPolicyWrite = NotificationPolicy(
      doNotDisturb: state.doNotDisturb,
      lockPreview: state.lockPreview,
    );
    if (!_policyWriteRunning) {
      unawaited(_drainPolicyWrites());
    }
  }

  Future<void> _drainPolicyWrites() async {
    _policyWriteRunning = true;
    try {
      while (true) {
        final policy = _pendingPolicyWrite;
        if (policy == null) {
          return;
        }
        _pendingPolicyWrite = null;
        await _policyStore!.write(policy);
      }
    } finally {
      _policyWriteRunning = false;
    }
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
