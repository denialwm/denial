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
    this.cachedBackdrop = false,
    this.surfaceBuilder,
    this.group,
    this.onExpandGroup,
    this.onDefaultAction,
    this.onAction,
  });

  static const horizontalMargin = MobileNotificationMetrics.horizontalMargin;

  final DesktopNotification notification;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final bool announce;
  final bool groupedBackdrop;
  final bool cachedBackdrop;
  final Widget Function(BuildContext, Widget)? surfaceBuilder;

  /// A collapsed group this card stands for; a tap runs [onExpandGroup].
  final DesktopNotificationGroup? group;
  final VoidCallback? onExpandGroup;

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
    final group = widget.group;
    if (group != null && group.stacked) return _buildGroup(context, group);
    final canOpen =
        widget.interactive &&
        widget.previewMode == NotificationPreviewMode.full &&
        widget.onDefaultAction != null &&
        widget.notification.opensApp;
    final card = NotificationCard(
      notification: widget.notification,
      mobile: true,
      announce: widget.announce,
      groupedBackdrop: widget.groupedBackdrop,
      cachedBackdrop: widget.cachedBackdrop,
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
            NotificationReveal.revealed(
              context,
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
            ),
        ],
      ),
    );
  }

  Widget _buildGroup(BuildContext context, DesktopNotificationGroup group) {
    final card = NotificationCard(
      notification: widget.notification,
      mobile: true,
      announce: widget.announce,
      groupedBackdrop: widget.groupedBackdrop,
      cachedBackdrop: widget.cachedBackdrop,
      showActions: false,
      previewMode: widget.previewMode,
      group: group,
      onExpandGroup: widget.interactive ? widget.onExpandGroup : null,
    );
    return widget.surfaceBuilder?.call(context, card) ?? card;
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
  Widget build(BuildContext context) {
    final metrics = MobileUiMetrics.of(context);
    return Semantics(
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
            dimension: metrics.visual(MobileNotificationMetrics.detailsExtent),
            child: Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: context.shellColors.textSecondary,
              size: metrics.visual(MobileNotificationMetrics.detailsIcon),
            ),
          ),
        ),
      ),
    );
  }
}
