part of 'notification_banner.dart';

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
    required this.entryOffset,
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
  final Offset entryOffset;
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
    final theme = ShellTheme.of(context);
    final interactive = widget.interactive && widget.visible;
    final position = Tween<Offset>(
      begin: widget.entryOffset,
      end: Offset.zero,
    ).animate(_curved);
    final card = NotificationCard(
      notification: widget.notification,
      previewMode: widget.previewMode,
      announce: true,
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

    return ClipRect(
      child: SizeTransition(
        sizeFactor: _curved,
        alignment: widget.entryOffset.dy > 0
            ? AlignmentDirectional.bottomStart
            : AlignmentDirectional.topStart,
        child: SlideTransition(
          position: position,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: RepaintBoundary(
              child: ShellBackdropBlur(
                blur: theme.panelOpacity < 1.0,
                borderRadius: BorderRadius.circular(theme.panelRadius),
                child: cardRegion,
              ),
            ),
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
