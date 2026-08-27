part of 'notification_banner.dart';

class NotificationCard extends StatelessWidget {
  const NotificationCard({
    required this.notification,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.announce = false,
    this.compact = false,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final DesktopNotification notification;
  final NotificationPreviewMode previewMode;
  final bool announce;
  final bool compact;
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
        ? l10n.notificationSemantics(appName, summary)
        : l10n.notificationSemanticsWithBody(appName, summary, body);
    final banner = !compact;

    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.panelColor(context.shellColors.surfaceContainerLow),
        gradient: banner
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  theme.panelColor(context.shellColors.panelBackground),
                  theme.panelColor(context.shellColors.panelBackgroundBottom),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(theme.panelRadius),
        border: Border.all(
          color: banner
              ? context.shellColors.hairline
              : context.shellColors.hairlineSoft,
        ),
        boxShadow: compact
            ? <BoxShadow>[]
            : <BoxShadow>[
                BoxShadow(
                  color: context.shellColors.shadow,
                  blurRadius: 22,
                  offset: Offset(0, 8),
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
                  separatorBuilder: (_, _) => const SizedBox(width: 7),
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
              color: context.shellColors.textSecondary,
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
    final normalized = value.clamp(0, 100).toInt();
    return Semantics(
      label: context.l10n.notificationProgress(normalized),
      value: context.l10n.settingsPercent(normalized),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
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
