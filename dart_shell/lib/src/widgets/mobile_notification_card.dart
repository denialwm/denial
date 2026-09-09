part of 'notification_banner.dart';

/// The same card presentation and expansion controls in heads-up and history.
class MobileNotificationCard extends StatefulWidget {
  const MobileNotificationCard({
    required this.notification,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.interactive = true,
    this.announce = false,
    this.groupedBackdrop = false,
    this.surfaceBuilder,
    this.onDefaultAction,
    this.onAction,
  });

  static const horizontalMargin = 16.0;

  final DesktopNotification notification;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final bool announce;
  final bool groupedBackdrop;
  final Widget Function(BuildContext, Widget)? surfaceBuilder;
  final VoidCallback? onDefaultAction;
  final ValueChanged<String>? onAction;

  @override
  State<MobileNotificationCard> createState() => _MobileNotificationCardState();
}

class _MobileNotificationCardState extends State<MobileNotificationCard> {
  bool _expanded = false;

  void _toggleExpanded() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final canOpen =
        widget.interactive &&
        widget.previewMode == NotificationPreviewMode.full &&
        widget.onDefaultAction != null &&
        widget.notification.actions.any((action) => action.key == 'default');
    final card = NotificationCard(
      notification: widget.notification,
      mobile: true,
      announce: widget.announce,
      groupedBackdrop: widget.groupedBackdrop,
      expanded: _expanded,
      showActions: _expanded,
      previewMode: widget.previewMode,
      onDefaultAction: canOpen ? widget.onDefaultAction : null,
      onAction: widget.interactive ? widget.onAction : null,
    );
    return Semantics(
      expanded: _expanded,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: !canOpen && widget.interactive ? _toggleExpanded : null,
            child: widget.surfaceBuilder?.call(context, card) ?? card,
          ),
          if (canOpen)
            Align(
              alignment: Alignment.centerRight,
              child: _MobileNotificationDetailsButton(
                label: context.l10n.quickSettingsOpenDetails(
                  widget.notification.summary,
                ),
                expanded: _expanded,
                onPressed: _toggleExpanded,
              ),
            ),
        ],
      ),
    );
  }
}

class _MobileNotificationDetailsButton extends StatelessWidget {
  const _MobileNotificationDetailsButton({
    required this.label,
    required this.expanded,
    required this.onPressed,
  });

  final String label;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: 48,
          child: Icon(
            expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            color: context.shellColors.textSecondary,
            size: 22,
          ),
        ),
      ),
    ),
  );
}
