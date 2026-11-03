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
    this.cachedBackdrop = false,
    this.expanded = false,
    this.showActions = true,
    this.group,
    this.onExpandGroup,
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

  /// Draw the enclosing [WindowBackdropCache]'s frost as the glass instead
  /// of filtering the live scene, when one is in scope.
  final bool cachedBackdrop;

  final bool expanded;
  final bool showActions;

  /// The stacked group this card, its newest member, stands for: a header
  /// with app, count and time, and lines for the next members.
  final DesktopNotificationGroup? group;

  /// A tap on a stacked card shows the group's members instead of opening.
  final VoidCallback? onExpandGroup;

  final VoidCallback? onDismiss;
  final VoidCallback? onDefaultAction;
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final mobileMetrics = MobileUiMetrics.of(context);
    final visual = mobileMetrics.visual;
    final l10n = context.l10n;
    final appName = notificationAppName(notification, l10n);
    final fullPreview = previewMode == NotificationPreviewMode.full;
    final summary = fullPreview
        ? (notification.summary.isEmpty
              ? l10n.notificationGeneric
              : notification.summary)
        : l10n.notificationNew;
    final messages = notification.messages;
    final body = !fullPreview
        ? ''
        : messages.isEmpty
        ? plainNotificationBody(notification.body)
        : notificationMessageLines(messages, l10n, expanded ? null : 2);
    final stack = group?.stacked ?? false ? group : null;
    var hasDefaultAction = false;
    final namedActions = <DesktopNotificationAction>[];
    if (fullPreview && stack == null) {
      for (final action in notification.actions) {
        if (action.key != 'default') namedActions.add(action);
      }
      hasDefaultAction = onDefaultAction != null && notification.opensApp;
    }
    final semanticLabel = body.isEmpty
        ? l10n.notificationSemantics(appName, summary)
        : l10n.notificationSemanticsWithBody(appName, summary, body);
    final banner = !compact && !mobile;

    final panelSurface = banner || mobile;
    final radius = BorderRadius.circular(
      mobile ? visual(theme.panelRadius) : theme.panelRadius,
    );
    final copy = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stack != null) ...[
          _NotificationGroupHeader(
            notification: notification,
            count: stack.members.length,
            mobile: mobile,
          ),
          SizedBox(
            height: mobile ? visual(MobileNotificationMetrics.copySpacing) : 4,
          ),
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
        if (stack != null && fullPreview)
          for (final record in stack.members.skip(1).take(2))
            _NotificationGroupLine(
              notification: record.notification,
              mobile: mobile,
            ),
        if (fullPreview && notification.hasProgress) ...[
          SizedBox(
            height: mobile
                ? visual(MobileNotificationMetrics.sectionSpacing)
                : 11,
          ),
          _NotificationProgress(
            value: notification.progress,
            visualScale: mobile ? visual(1) : 1,
          ),
        ],
        if (showActions && namedActions.isNotEmpty && onAction != null) ...[
          SizedBox(
            height: mobile
                ? visual(MobileNotificationMetrics.sectionSpacing)
                : 11,
          ),
          SizedBox(
            height: mobile
                ? visual(MobileNotificationMetrics.actionHeight)
                : 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: namedActions.length,
              separatorBuilder: (_, _) => SizedBox(
                width: mobile
                    ? visual(MobileNotificationMetrics.actionSpacing)
                    : 7,
              ),
              itemBuilder: (context, index) {
                final action = namedActions[index];
                return _NotificationActionButton(
                  label: action.label.isEmpty ? action.key : action.label,
                  mobile: mobile,
                  fontSize: mobile
                      ? MobileNotificationMetrics.actionFontSize
                      : 12,
                  visualScale: mobile ? visual(1) : 1,
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
        // A phone's notifications are cards, wherever they show; in glass
        // their opacity is the panels' anyway.
        gradient: !panelSurface
            ? null
            : mobile
            ? theme.cardGradient(
                context.shellColors.panelBackground,
                context.shellColors.panelBackgroundBottom,
              )
            : theme.panelGradient(
                context.shellColors.panelBackground,
                context.shellColors.panelBackgroundBottom,
              ),
        borderRadius: radius,
        border: mobile && theme.transparencyMode == ShellTransparencyMode.glass
            ? null
            : Border.all(
                color: panelSurface
                    ? context.shellColors.hairline
                    : context.shellColors.hairlineSoft,
              ),
      ),
      child: Padding(
        padding: mobile
            ? mobileMetrics.visualInsets(
                left: MobileNotificationMetrics.horizontalContentInset,
                top: MobileNotificationMetrics.verticalContentInset,
                right: MobileNotificationMetrics.horizontalContentInset,
                bottom: MobileNotificationMetrics.verticalContentInset,
              )
            : EdgeInsets.fromLTRB(
                compact ? 12 : 14,
                compact ? 11 : 13,
                compact ? 10 : 12,
                compact ? 12 : 14,
              ),
        child: mobile
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NotificationArtwork(
                    notification: notification,
                    size: visual(MobileNotificationMetrics.leadingArtwork),
                    preferContentImage: fullPreview,
                  ),
                  SizedBox(width: visual(MobileNotificationMetrics.leadingGap)),
                  Expanded(child: copy),
                  if (onDismiss != null)
                    _NotificationIconButton(
                      label: l10n.notificationDismiss,
                      icon: Icons.close_rounded,
                      visualScale: visual(1),
                      onPressed: onDismiss!,
                    ),
                ],
              )
            : copy,
      ),
    );

    final cache = mobile && cachedBackdrop && theme.effectivePanelOpacity < 1.0
        ? WindowBackdropCache.maybeOf(context)
        : null;
    final Widget content;
    if (!mobile) {
      content = decoration;
    } else if (cache != null) {
      // The shared frost replaces a live blur pass per card.
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: WindowBackdropSlice(
              cache: cache,
              borderRadius: radius,
              glass: theme.windowGlassShading,
              opacity: NotificationReveal.maybeOf(context),
              fadeOverlay: true,
            ),
          ),
          NotificationReveal.revealed(context, decoration),
        ],
      );
    } else {
      content = ShellBackdropBlur(
        grouped: groupedBackdrop,
        blur:
            !ShadeBackdropScene.sharesBlur(context) &&
            theme.effectivePanelOpacity < 1.0,
        separateChild: true,
        borderRadius: radius,
        child: decoration,
      );
    }

    final expandGroup = stack == null ? null : onExpandGroup;
    final activate = expandGroup ?? (hasDefaultAction ? onDefaultAction : null);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: announce
          ? notification.urgency == DesktopNotificationUrgency.critical
                ? .alert
                : .status
          : null,
      button: activate != null,
      expanded: stack == null ? null : false,
      label: semanticLabel,
      onTap: activate,
      onDismiss: onDismiss,
      child: activate != null
          ? _NotificationActivator(
              semanticLabel: stack == null
                  ? l10n.notificationOpen(summary)
                  : l10n.notificationGroupExpand(stack.members.length, appName),
              onActivate: activate,
              borderRadius: radius,
              child: content,
            )
          : content,
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
    final visual = MobileUiMetrics.of(context).visual;
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
            fontSize: mobile
                ? MobileNotificationMetrics.titleFontSize
                : (compact ? 13.5 : 14.5),
            fontWeight: mobile ? FontWeight.w700 : FontWeight.w600,
            height: 1.2,
            letterSpacing: 0,
          ),
        ),
        if (body.isNotEmpty) ...[
          SizedBox(
            height: mobile ? visual(MobileNotificationMetrics.copySpacing) : 4,
          ),
          Text(
            body,
            maxLines: expanded ? null : (mobile || compact ? 2 : 3),
            overflow: TextOverflow.ellipsis,
            style: ShellText.base.copyWith(
              color: mobile
                  ? context.shellColors.textPrimary
                  : context.shellColors.textSecondary,
              fontSize: mobile
                  ? MobileNotificationMetrics.bodyFontSize
                  : (compact ? 12 : 12.5),
              fontWeight: FontWeight.w400,
              height: 1.34,
            ),
          ),
        ],
      ],
    );
    if (mobile) {
      return copy;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NotificationArtwork(
          notification: notification,
          size: compact ? 58 : 68,
          preferContentImage: fullPreview,
        ),
        const SizedBox(width: 11),
        Expanded(child: copy),
      ],
    );
  }
}

class _NotificationProgress extends StatelessWidget {
  const _NotificationProgress({required this.value, this.visualScale = 1});

  final int value;
  final double visualScale;

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(0, 100).toInt();
    return Semantics(
      label: context.l10n.notificationProgress(normalized),
      value: context.l10n.settingsPercent(normalized),
      child: ClipRRect(
        borderRadius: context.shellTheme.borderRadius(2 * visualScale),
        child: SizedBox(
          height: MobileNotificationMetrics.progressHeight * visualScale,
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

/// A conversation's last [count] messages, one per line; all when null.
String notificationMessageLines(
  List<DesktopNotificationMessage> messages,
  AppLocalizations l10n, [
  int? count,
]) {
  final shown = count == null || messages.length <= count
      ? messages
      : messages.sublist(messages.length - count);
  return [
    for (final message in shown)
      message.sender.isEmpty
          ? message.text
          : l10n.notificationMessage(message.sender, message.text),
  ].join('\n');
}

/// App, count and time of the newest member, above a stacked group's card.
class _NotificationGroupHeader extends StatelessWidget {
  const _NotificationGroupHeader({
    required this.notification,
    required this.count,
    required this.mobile,
  });

  final DesktopNotification notification;
  final int count;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final header = l10n.notificationGroupHeader(
      notificationAppName(notification, l10n),
      count,
    );
    final time = notification.timeMs > 0
        ? _notificationTime(
            context,
            DateTime.fromMillisecondsSinceEpoch(notification.timeMs),
          )
        : null;
    return Text(
      time == null ? header : '$header · $time',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ShellText.base.copyWith(
        color: context.shellColors.textSecondary,
        fontSize: mobile ? MobileNotificationMetrics.groupHeaderFontSize : 11.5,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    );
  }
}

String _notificationTime(BuildContext context, DateTime time) {
  final now = DateTime.now();
  final today =
      time.year == now.year && time.month == now.month && time.day == now.day;
  return today
      ? localizedTime(context, time)
      : localizedShortDate(context, time);
}

/// One more member of a stacked group, on a single line under the newest.
class _NotificationGroupLine extends StatelessWidget {
  const _NotificationGroupLine({
    required this.notification,
    required this.mobile,
  });

  final DesktopNotification notification;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final messages = notification.messages;
    final detail = messages.isEmpty
        ? plainNotificationBody(notification.body)
        : notificationMessageLines(messages, l10n, 1);
    final visual = MobileUiMetrics.of(context).visual;
    final fontSize = mobile ? MobileNotificationMetrics.bodyFontSize : 12.0;
    return Padding(
      padding: EdgeInsets.only(
        top: mobile ? visual(MobileNotificationMetrics.copySpacing) : 3,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: notification.summary.isEmpty
                  ? l10n.notificationGeneric
                  : notification.summary,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (detail.isNotEmpty)
              TextSpan(text: '  ${detail.split('\n').first}'),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ShellText.base.copyWith(
          color: context.shellColors.textSecondary,
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
          height: 1.3,
        ),
      ),
    );
  }
}
