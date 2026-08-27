import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../localization/denial_localizations.dart';
import '../input/shell_interaction_registry.dart';
import '../models/desktop_notification.dart';
import '../models/shell_popup_placement.dart';
import '../settings/settings_controller.dart';
import '../services/notification_policy_repository.dart';
import '../state/desktop_notifications.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'notification_media.dart';
import 'shell_backdrop_blur.dart';

part 'notification_card.dart';
part 'notification_card_controls.dart';
part 'notification_transition.dart';

class NotificationBannerLayer extends ConsumerWidget {
  const NotificationBannerLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationState = ref.watch(desktopNotificationsProvider);
    final locked = ref.watch(
      shellControllerProvider.select((state) => state.lockLayerVisible),
    );
    final previewMode = locked
        ? notificationState.lockPreview
        : NotificationPreviewMode.full;
    final notifications =
        locked && previewMode == NotificationPreviewMode.hidden
        ? const <DesktopNotification>[]
        : notificationState.bannerNotifications;
    final controller = ref.read(desktopNotificationsProvider.notifier);
    final placement = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.overlays.notifications,
      ),
    );
    final mainOutput = ref.watch(
      displayLayoutProvider.select((layout) => layout?.mainOutput),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvas = Offset.zero & constraints.biggest;
        final output = mainOutput?.logicalRect.intersect(canvas) ?? canvas;
        final rect = placement.resolve(output);
        if (rect.isEmpty) {
          return const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: Align(
                alignment: placement.anchor.alignment,
                child: SizedBox(
                  width: rect.width,
                  child: NotificationBannerView(
                    notifications: notifications,
                    previewMode: previewMode,
                    interactive: !locked,
                    entryOffset: _notificationEntryOffset(placement.anchor),
                    onDismiss: controller.dismiss,
                    onDefaultAction: controller.invokeDefaultAction,
                    onAction: controller.invokeAction,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class NotificationBannerView extends StatefulWidget {
  const NotificationBannerView({
    required this.notifications,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.interactive = true,
    this.entryOffset = const Offset(0, -1),
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final List<DesktopNotification> notifications;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final Offset entryOffset;
  final bool Function(int notificationId)? onDismiss;
  final bool Function(int notificationId)? onDefaultAction;
  final bool Function(int notificationId, String actionKey)? onAction;

  @override
  State<NotificationBannerView> createState() => _NotificationBannerViewState();
}

class _NotificationBannerViewState extends State<NotificationBannerView> {
  static const int _maxPresentedNotifications =
      DesktopNotificationsState.maxVisibleBanners * 2;

  final Map<int, Timer> _removalTimers = <int, Timer>{};
  late final List<_PresentedNotification> _displayed;
  int _nextExitSequence = 1;

  @override
  void initState() {
    super.initState();
    _displayed = widget.notifications
        .take(DesktopNotificationsState.maxVisibleBanners)
        .map(_PresentedNotification.visible)
        .toList(growable: true);
  }

  @override
  void didUpdateWidget(covariant NotificationBannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronizeNotifications();
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.notificationBanner;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in _displayed)
          _NotificationTransition(
            key: ValueKey<int>(entry.notification.id),
            duration: duration,
            notification: entry.notification,
            visible: entry.visible,
            entryOffset: widget.entryOffset,
            previewMode: widget.previewMode,
            interactive: widget.interactive,
            onDismiss: widget.onDismiss,
            onDefaultAction: widget.onDefaultAction,
            onAction: widget.onAction,
          ),
      ],
    );
  }

  void _synchronizeNotifications() {
    final incoming = widget.notifications
        .take(DesktopNotificationsState.maxVisibleBanners)
        .toList(growable: false);
    final incomingIds = incoming.map((notification) => notification.id).toSet();
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.notificationBanner;

    for (final entry in _displayed) {
      final id = entry.notification.id;
      if (incomingIds.contains(id) || !entry.visible) {
        continue;
      }
      entry.visible = false;
      entry.exitSequence = _nextExitSequence++;
      _removalTimers[id]?.cancel();
      _removalTimers[id] = Timer(duration, () => _removeAfterExit(id));
    }

    for (final notification in incoming) {
      final index = _displayed.indexWhere(
        (entry) => entry.notification.id == notification.id,
      );
      if (index < 0) {
        _displayed.add(_PresentedNotification.visible(notification));
        continue;
      }
      final entry = _displayed[index];
      entry
        ..notification = notification
        ..visible = true
        ..exitSequence = null;
      _removalTimers.remove(notification.id)?.cancel();
    }

    _displayed.sort((left, right) {
      final leftIndex = incoming.indexWhere(
        (notification) => notification.id == left.notification.id,
      );
      final rightIndex = incoming.indexWhere(
        (notification) => notification.id == right.notification.id,
      );
      if (leftIndex >= 0 || rightIndex >= 0) {
        if (leftIndex < 0) {
          return 1;
        }
        if (rightIndex < 0) {
          return -1;
        }
        return leftIndex.compareTo(rightIndex);
      }
      return (right.exitSequence ?? 0).compareTo(left.exitSequence ?? 0);
    });

    if (_displayed.length > _maxPresentedNotifications) {
      final removed = _displayed.sublist(_maxPresentedNotifications);
      _displayed.removeRange(_maxPresentedNotifications, _displayed.length);
      for (final entry in removed) {
        _removalTimers.remove(entry.notification.id)?.cancel();
      }
    }
  }

  void _removeAfterExit(int notificationId) {
    _removalTimers.remove(notificationId);
    if (!mounted ||
        widget.notifications.any(
          (notification) => notification.id == notificationId,
        )) {
      return;
    }
    setState(() {
      _displayed.removeWhere(
        (entry) => entry.notification.id == notificationId,
      );
    });
  }

  @override
  void dispose() {
    for (final timer in _removalTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
