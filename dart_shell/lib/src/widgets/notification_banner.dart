import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../models/desktop_notification.dart';
import '../services/notification_policy_repository.dart';
import '../state/desktop_notifications.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'notification_media.dart';

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
    final horizontalInset = MediaQuery.sizeOf(context).width < 480
        ? 10.0
        : 16.0;

    return Positioned.fill(
      child: SafeArea(
        minimum: EdgeInsets.symmetric(
          horizontal: horizontalInset,
          vertical: 14,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 410),
            child: NotificationBannerView(
              notifications: notifications,
              previewMode: previewMode,
              interactive: !locked,
              onDismiss: controller.dismiss,
              onDefaultAction: controller.invokeDefaultAction,
              onAction: controller.invokeAction,
            ),
          ),
        ),
      ),
    );
  }
}

class NotificationBannerView extends StatefulWidget {
  const NotificationBannerView({
    required this.notifications,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.interactive = true,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final List<DesktopNotification> notifications;
  final NotificationPreviewMode previewMode;
  final bool interactive;
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
      children: [
        for (final entry in _displayed)
          _NotificationTransition(
            key: ValueKey<int>(entry.notification.id),
            duration: duration,
            notification: entry.notification,
            visible: entry.visible,
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

class _PresentedNotification {
  _PresentedNotification.visible(this.notification) : visible = true;

  DesktopNotification notification;
  bool visible;
  int? exitSequence;
}

class _NotificationTransition extends StatefulWidget {
  const _NotificationTransition({
    required this.duration,
    required this.notification,
    required this.visible,
    required this.previewMode,
    required this.interactive,
    required this.onDismiss,
    required this.onDefaultAction,
    required this.onAction,
    super.key,
  });

  final Duration duration;
  final DesktopNotification notification;
  final bool visible;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final bool Function(int notificationId)? onDismiss;
  final bool Function(int notificationId)? onDefaultAction;
  final bool Function(int notificationId, String actionKey)? onAction;

  @override
  State<_NotificationTransition> createState() =>
      _NotificationTransitionState();
}

class _NotificationTransitionState extends State<_NotificationTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
  late final Animation<Offset> _position;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.duration,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: Motion.md3EmphasizedDecelerate,
      reverseCurve: Motion.md3EmphasizedAccelerate,
    );
    _position = Tween<Offset>(
      begin: const Offset(-0.08, -0.18),
      end: Offset.zero,
    ).animate(_curved);
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _NotificationTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller
        ..duration = widget.duration
        ..reverseDuration = widget.duration;
    }
    if (oldWidget.visible == widget.visible) {
      return;
    }
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.interactive && widget.visible;
    final card = NotificationCard(
      notification: widget.notification,
      previewMode: widget.previewMode,
      liveRegion: true,
      onDismiss: interactive && widget.onDismiss != null
          ? () => widget.onDismiss!(widget.notification.id)
          : null,
      onDefaultAction: interactive && widget.onDefaultAction != null
          ? () => widget.onDefaultAction!(widget.notification.id)
          : null,
      onAction: interactive && widget.onAction != null
          ? (actionKey) => widget.onAction!(widget.notification.id, actionKey)
          : null,
    );
    final cardRegion = interactive
        ? ShellInputRegion(
            debugLabel: 'Notification ${widget.notification.id}',
            child: card,
          )
        : IgnorePointer(child: card);

    return SizeTransition(
      sizeFactor: _curved,
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: _curved,
        child: SlideTransition(
          position: _position,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: RepaintBoundary(child: cardRegion),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }
}

class NotificationCard extends StatelessWidget {
  const NotificationCard({
    required this.notification,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.liveRegion = false,
    this.compact = false,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final DesktopNotification notification;
  final NotificationPreviewMode previewMode;
  final bool liveRegion;
  final bool compact;
  final VoidCallback? onDismiss;
  final VoidCallback? onDefaultAction;
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final appName = notificationAppName(notification);
    final fullPreview = previewMode == NotificationPreviewMode.full;
    final summary = fullPreview
        ? (notification.summary.isEmpty ? 'Notification' : notification.summary)
        : 'New notification';
    final body = fullPreview ? plainNotificationBody(notification.body) : '';
    final hasDefaultAction =
        fullPreview &&
        onDefaultAction != null &&
        notification.actions.any((action) => action.key == 'default');
    final namedActions = fullPreview
        ? notification.actions
              .where((action) => action.key != 'default')
              .toList(growable: false)
        : const <DesktopNotificationAction>[];
    final semanticLabel = body.isEmpty
        ? '$appName notification. $summary'
        : '$appName notification. $summary. $body';

    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ShellRadii.notification),
        border: Border.all(color: ShellColors.hairlineSoft),
        boxShadow: compact
            ? const <BoxShadow>[]
            : const <BoxShadow>[
                BoxShadow(
                  color: ShellColors.shadowSoft,
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 14,
          compact ? 11 : 13,
          compact ? 10 : 12,
          compact ? 12 : 14,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NotificationHeader(
              notification: notification,
              appName: appName,
              onDismiss: onDismiss,
            ),
            SizedBox(height: compact ? 8 : 10),
            _NotificationBody(
              notification: notification,
              summary: summary,
              body: body,
              fullPreview: fullPreview,
              compact: compact,
            ),
            if (fullPreview && notification.hasProgress) ...[
              const SizedBox(height: 11),
              _NotificationProgress(value: notification.progress),
            ],
            if (namedActions.isNotEmpty && onAction != null) ...[
              const SizedBox(height: 11),
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: namedActions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 7),
                  itemBuilder: (context, index) {
                    final action = namedActions[index];
                    return _NotificationActionButton(
                      label: action.label.isEmpty ? action.key : action.label,
                      onPressed: () => onAction!(action.key),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: liveRegion,
      button: hasDefaultAction,
      label: semanticLabel,
      onTap: hasDefaultAction ? onDefaultAction : null,
      child: hasDefaultAction
          ? _NotificationActivator(
              semanticLabel: 'Open $summary',
              onActivate: onDefaultAction!,
              child: content,
            )
          : content,
    );
  }
}

class _NotificationHeader extends StatelessWidget {
  const _NotificationHeader({
    required this.notification,
    required this.appName,
    required this.onDismiss,
  });

  final DesktopNotification notification;
  final String appName;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final indicator = switch (notification.urgency) {
      DesktopNotificationUrgency.low => ShellColors.textTertiary,
      DesktopNotificationUrgency.normal => ShellColors.accent,
      DesktopNotificationUrgency.critical => ShellColors.performanceBad,
    };
    return Row(
      children: [
        NotificationArtwork(
          notification: notification,
          size: 34,
          preferContentImage: false,
        ),
        const SizedBox(width: 10),
        DecoratedBox(
          decoration: BoxDecoration(color: indicator, shape: BoxShape.circle),
          child: const SizedBox.square(dimension: 6),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            appName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShellText.base.copyWith(
              color: ShellColors.textTertiary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ),
        if (notification.resident)
          const Padding(
            padding: EdgeInsets.only(right: 7),
            child: Icon(
              Icons.push_pin_rounded,
              size: 14,
              color: ShellColors.textTertiary,
            ),
          ),
        if (onDismiss != null)
          _NotificationIconButton(
            label: 'Dismiss notification',
            icon: Icons.close_rounded,
            onPressed: onDismiss!,
          ),
      ],
    );
  }
}

class _NotificationBody extends StatelessWidget {
  const _NotificationBody({
    required this.notification,
    required this.summary,
    required this.body,
    required this.fullPreview,
    required this.compact,
  });

  final DesktopNotification notification;
  final String summary;
  final String body;
  final bool fullPreview;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final copy = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          summary,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: ShellText.cardTitle.copyWith(
            fontSize: compact ? 13.5 : 14.5,
            height: 1.2,
            letterSpacing: 0,
          ),
        ),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            body,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: ShellText.base.copyWith(
              color: ShellColors.textSecondary,
              fontSize: compact ? 12 : 12.5,
              height: 1.34,
            ),
          ),
        ],
      ],
    );
    final hasImage =
        fullPreview &&
        (notification.imageData != null || notification.imagePath.isNotEmpty);
    if (!hasImage) {
      return copy;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NotificationArtwork(
          notification: notification,
          size: compact ? 58 : 68,
        ),
        const SizedBox(width: 11),
        Expanded(child: copy),
      ],
    );
  }
}

class _NotificationProgress extends StatelessWidget {
  const _NotificationProgress({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(0, 100);
    return Semantics(
      label: 'Progress $normalized percent',
      value: '$normalized%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: ShellColors.surfaceContainerHighest),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: normalized / 100,
                child: const ColoredBox(color: ShellColors.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationActivator extends StatefulWidget {
  const _NotificationActivator({
    required this.semanticLabel,
    required this.onActivate,
    required this.child,
  });

  final String semanticLabel;
  final VoidCallback onActivate;
  final Widget child;

  @override
  State<_NotificationActivator> createState() => _NotificationActivatorState();
}

class _NotificationActivatorState extends State<_NotificationActivator> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onActivate,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ShellRadii.notification),
            border: _focused
                ? Border.all(color: ShellColors.accent, width: 1.5)
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _NotificationActionButton extends StatefulWidget {
  const _NotificationActionButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  State<_NotificationActionButton> createState() =>
      _NotificationActionButtonState();
}

class _NotificationActionButtonState extends State<_NotificationActionButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            curve: Motion.standard,
            constraints: const BoxConstraints(minWidth: 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered || _focused
                  ? ShellColors.primaryContainer
                  : ShellColors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? ShellColors.accent : ShellColors.hairlineSoft,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.cardTitle.copyWith(fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationIconButton extends StatefulWidget {
  const _NotificationIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_NotificationIconButton> createState() =>
      _NotificationIconButtonState();
}

class _NotificationIconButtonState extends State<_NotificationIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hovered || _focused
                  ? ShellColors.surfaceContainerHighest
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(11),
              border: _focused ? Border.all(color: ShellColors.accent) : null,
            ),
            child: Icon(
              widget.icon,
              size: 17,
              color: ShellColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

String notificationAppName(DesktopNotification notification) {
  if (notification.appName.isNotEmpty) {
    return notification.appName;
  }
  if (notification.desktopEntry.isNotEmpty) {
    return notification.desktopEntry;
  }
  return 'Notification';
}

String plainNotificationBody(String value) {
  return value
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&')
      .trim();
}
