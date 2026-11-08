import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import 'mobile_ui_metrics.dart';
import 'notification_media.dart';
import 'notification_open.dart';

export 'notification_open.dart' show openLockNotification, openNotification;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/rendering.dart'
    show FadeSnapshot, WindowBackdropCache, WindowBackdropSlice;

import 'shade/shade_backdrop_scene.dart';
import '../state/phone_desk.dart';

part 'notification_card.dart';
part 'notification_reveal.dart';
part 'notification_card_controls.dart';
part 'notification_transition.dart';
part 'mobile_notification_banner.dart';
part 'mobile_notification_card.dart';

class NotificationBannerLayer extends ConsumerWidget {
  const NotificationBannerLayer({super.key, this.mobile = false});

  final bool mobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!showsTransientOverlay(context, ref)) return const SizedBox.shrink();
    final notificationState = ref.watch(desktopNotificationsProvider);
    final locked = ref.watch(
      referenceShellProvider.select((state) => state.lockLayerVisible),
    );
    // The lock screen has its own notification cards; a transient banner
    // would sit on top of the credential card.
    if (locked) return const SizedBox.shrink();
    final previewMode = NotificationPreviewMode.full;
    final notifications = notificationState.bannerNotifications;
    final controller = ref.read(desktopNotificationsProvider.notifier);
    if (mobile) {
      final shadeVisible = ref.watch(
        referenceShellProvider.select((state) => state.quickSettingsEngaged),
      );
      return MobileNotificationBannerView(
        notification: shadeVisible || notifications.isEmpty
            ? null
            : notifications.first,
        previewMode: previewMode,
        interactive: !locked,
        onHide: controller.hideBanner,
        onDismiss: controller.dismiss,
        onDefaultAction: (id) => openNotification(ref, id),
        onAction: controller.invokeAction,
      );
    }
    final placement = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.overlays.notifications,
      ),
    );
    final mainOutput = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context))
          .select((layout) => layout?.mainOutput),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvas = Offset.zero & constraints.biggest;
        final output = mainOutput?.logicalRect.intersect(canvas) ?? canvas;
        final rect = placement.resolve(output);
        if (rect.isEmpty) {
          return const SizedBox.shrink();
        }
        final localRect = rect.shift(-output.topLeft);
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: output,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fromRect(
                      rect: localRect,
                      child: Align(
                        alignment: placement.anchor.alignment,
                        child: SizedBox(
                          width: rect.width,
                          child: NotificationBannerView(
                            notifications: notifications,
                            previewMode: previewMode,
                            interactive: !locked,
                            entryOffset: _notificationEntryOffset(
                              placement.anchor,
                            ),
                            onHide: controller.hideBanner,
                            onDismiss: controller.dismiss,
                            onDefaultAction: (id) => openNotification(ref, id),
                            onAction: controller.invokeAction,
                          ),
                        ),
                      ),
                    ),
                  ],
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
    this.onHide,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final List<DesktopNotification> notifications;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final Offset entryOffset;

  /// Ends a banner whose time is up; the notification stays in history.
  final ValueChanged<int>? onHide;
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
  final Map<int, Timer> _hideTimers = <int, Timer>{};
  late final List<_PresentedNotification> _displayed;
  int _nextExitSequence = 1;

  @override
  void initState() {
    super.initState();
    _displayed = widget.notifications
        .take(DesktopNotificationsState.maxVisibleBanners)
        .map(_PresentedNotification.visible)
        .toList(growable: true);
    for (final entry in _displayed) {
      _armHide(entry.notification);
    }
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
      _hideTimers.remove(id)?.cancel();
      _removalTimers[id]?.cancel();
      _removalTimers[id] = Timer(duration, () => _removeAfterExit(id));
    }

    for (final notification in incoming) {
      final index = _displayed.indexWhere(
        (entry) => entry.notification.id == notification.id,
      );
      if (index < 0) {
        _displayed.add(_PresentedNotification.visible(notification));
        _armHide(notification);
        continue;
      }
      final entry = _displayed[index];
      // A banner shown again, or an update that alerts, gets its full time.
      if (!entry.visible ||
          (notification.alert &&
              !identical(entry.notification, notification))) {
        _armHide(notification);
      }
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

  void _armHide(DesktopNotification notification) {
    final id = notification.id;
    _hideTimers.remove(id)?.cancel();
    final duration = notification.bannerDuration;
    if (duration == null) return;
    _hideTimers[id] = Timer(duration, () {
      _hideTimers.remove(id);
      if (mounted) widget.onHide?.call(id);
    });
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
    for (final timer in [..._removalTimers.values, ..._hideTimers.values]) {
      timer.cancel();
    }
    super.dispose();
  }
}
