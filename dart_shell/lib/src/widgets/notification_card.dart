part of 'notification_banner.dart';

class NotificationCard extends StatelessWidget {
  const NotificationCard({
    required this.notification,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.announce = false,
    this.compact = false,
    this.mobile = false,
    this.groupedBackdrop = false,
    this.expanded = false,
    this.showActions = true,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final DesktopNotification notification;
  final NotificationPreviewMode previewMode;
  final bool announce;
  final bool compact;
  final bool mobile;
  final bool groupedBackdrop;

  final bool expanded;
  final bool showActions;
  final VoidCallback? onDismiss;
  final VoidCallback? onDefaultAction;
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    final appName = notificationAppName(notification, l10n);
    final fullPreview = previewMode == NotificationPreviewMode.full;
    final summary = fullPreview
        ? (notification.summary.isEmpty
              ? l10n.notificationGeneric
              : notification.summary)
        : l10n.notificationNew;
    final body = fullPreview ? plainNotificationBody(notification.body) : '';
    var hasDefaultAction = false;
    final namedActions = <DesktopNotificationAction>[];
    if (fullPreview) {
      for (final action in notification.actions) {
        if (action.key == 'default') {
          hasDefaultAction = onDefaultAction != null;
        } else {
          namedActions.add(action);
        }
      }
    }
    final semanticLabel = body.isEmpty
        ? l10n.notificationSemantics(appName, summary)
        : l10n.notificationSemanticsWithBody(appName, summary, body);
    final banner = !compact && !mobile;

    final panelSurface = banner || mobile;
    final radius = BorderRadius.circular(theme.panelRadius);
    final copy = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!mobile) ...[
          _NotificationHeader(
            notification: notification,
            appName: appName,
            onDismiss: onDismiss,
          ),
          SizedBox(height: compact ? 8 : 10),
        ],
        _NotificationBody(
          notification: notification,
          summary: mobile && !fullPreview ? appName : summary,
          body: mobile && !fullPreview ? l10n.notificationNew : body,
          fullPreview: fullPreview,
          compact: compact,
          mobile: mobile,
          expanded: expanded,
        ),
        if (fullPreview && notification.hasProgress) ...[
          const SizedBox(height: 11),
          _NotificationProgress(value: notification.progress),
        ],
        if (showActions && namedActions.isNotEmpty && onAction != null) ...[
          const SizedBox(height: 11),
          SizedBox(
            height: mobile ? 48 : 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: namedActions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 7),
              itemBuilder: (context, index) {
                final action = namedActions[index];
                return _NotificationActionButton(
                  label: action.label.isEmpty ? action.key : action.label,
                  fontSize: mobile ? 17 : 12,
                  textColor: mobile ? context.shellColors.textPrimary : null,
                  onPressed: () => onAction!(action.key),
                );
              },
            ),
          ),
        ],
      ],
    );

    final decoration = DecoratedBox(
      decoration: BoxDecoration(
        color: panelSurface
            ? null
            : theme.cardColor(context.shellColors.surfaceContainerLow),
        gradient: panelSurface
            ? theme.panelGradient(
                context.shellColors.panelBackground,
                context.shellColors.panelBackgroundBottom,
              )
            : null,
        borderRadius: radius,
        border: Border.all(
          color: panelSurface
              ? context.shellColors.hairline
              : context.shellColors.hairlineSoft,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          mobile ? 20 : (compact ? 12 : 14),
          mobile ? 20 : (compact ? 11 : 13),
          mobile ? 20 : (compact ? 10 : 12),
          mobile ? 20 : (compact ? 12 : 14),
        ),
        child: mobile
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NotificationArtwork(
                    notification: notification,
                    size: 56,
                    preferContentImage: false,
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: copy),
                  if (onDismiss != null)
                    _NotificationIconButton(
                      label: l10n.notificationDismiss,
                      icon: Icons.close_rounded,
                      onPressed: onDismiss!,
                    ),
                ],
              )
            : copy,
      ),
    );

    final content = mobile
        ? ShellBackdropBlur(
            grouped: groupedBackdrop,
            blur:
                !ShadeBackdropScene.sharesBlur(context) &&
                theme.effectivePanelOpacity < 1.0,
            separateChild: true,
            borderRadius: radius,
            child: decoration,
          )
        : decoration;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: announce
          ? notification.urgency == DesktopNotificationUrgency.critical
                ? .alert
                : .status
          : null,
      button: hasDefaultAction,
      label: semanticLabel,
      onTap: hasDefaultAction ? onDefaultAction : null,
      child: hasDefaultAction
          ? _NotificationActivator(
              semanticLabel: l10n.notificationOpen(summary),
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
      DesktopNotificationUrgency.low => context.shellColors.textTertiary,
      DesktopNotificationUrgency.normal => ShellTheme.of(context).accent,
      DesktopNotificationUrgency.critical => context.shellColors.performanceBad,
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
              color: context.shellColors.textTertiary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ),
        if (notification.resident)
          Padding(
            padding: EdgeInsets.only(right: 7),
            child: Icon(
              Icons.push_pin_rounded,
              size: 14,
              color: context.shellColors.textTertiary,
            ),
          ),
        if (onDismiss != null)
          _NotificationIconButton(
            label: context.l10n.notificationDismiss,
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
    this.mobile = false,
    this.expanded = false,
  });

  final DesktopNotification notification;
  final String summary;
  final String body;
  final bool fullPreview;
  final bool compact;
  final bool mobile;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final copy = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          summary,
          maxLines: expanded ? null : (mobile ? 1 : 2),
          overflow: TextOverflow.ellipsis,
          style: ShellText.cardTitle.copyWith(
            color: mobile ? context.shellColors.textPrimary : null,
            fontSize: mobile ? 20 : (compact ? 13.5 : 14.5),
            fontWeight: mobile ? FontWeight.w700 : FontWeight.w600,
            height: 1.2,
            letterSpacing: 0,
          ),
        ),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            body,
            maxLines: expanded ? null : (mobile || compact ? 2 : 3),
            overflow: TextOverflow.ellipsis,
            style: ShellText.base.copyWith(
              color: mobile
                  ? context.shellColors.textPrimary
                  : context.shellColors.textSecondary,
              fontSize: mobile ? 18 : (compact ? 12 : 12.5),
              fontWeight: FontWeight.w400,
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
        if (mobile) Expanded(child: copy),
        if (mobile) const SizedBox(width: 12),
        NotificationArtwork(
          notification: notification,
          size: mobile ? 48 : (compact ? 58 : 68),
        ),
        if (!mobile) const SizedBox(width: 11),
        if (!mobile) Expanded(child: copy),
      ],
    );
  }
}

class _NotificationProgress extends StatelessWidget {
  const _NotificationProgress({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(0, 100).toInt();
    return Semantics(
      label: context.l10n.notificationProgress(normalized),
      value: context.l10n.settingsPercent(normalized),
      child: ClipRRect(
        borderRadius: context.shellTheme.borderRadius(2),
        child: SizedBox(
          height: 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: context.shellColors.surfaceContainerHighest),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: normalized / 100,
                child: ColoredBox(color: ShellTheme.of(context).accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
