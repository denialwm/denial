import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../localization/denial_localizations.dart';
import '../services/notification_policy_repository.dart';
import '../state/desktop_notifications.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'notification_banner.dart';

class NotificationCenter extends ConsumerStatefulWidget {
  const NotificationCenter({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  ConsumerState<NotificationCenter> createState() => _NotificationCenterState();
}

class _NotificationCenterState extends ConsumerState<NotificationCenter> {
  bool _markReadScheduled = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopNotificationsProvider);
    final controller = ref.read(desktopNotificationsProvider.notifier);
    final records = state.history;
    if (state.unreadCount > 0 && !_markReadScheduled) {
      _markReadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _markReadScheduled = false;
        if (mounted) {
          ref.read(desktopNotificationsProvider.notifier).markAllRead();
        }
      });
    }

    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NotificationCenterHeader(
            showTitle: widget.showTitle,
            unreadCount: state.unreadCount,
            doNotDisturb: state.doNotDisturb,
            policyLoaded: state.policyLoaded,
            hasNotifications: records.isNotEmpty || state.active.isNotEmpty,
            onToggleDoNotDisturb: controller.toggleDoNotDisturb,
            onClearAll: controller.clearAll,
          ),
          const SizedBox(height: 10),
          _PrivacyModeSelector(
            selected: state.lockPreview,
            enabled: state.policyLoaded,
            onSelected: controller.setLockPreview,
          ),
          const SizedBox(height: 10),
          if (state.doNotDisturb)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: _DoNotDisturbNotice(),
            ),
          Expanded(
            child: records.isEmpty
                ? const _NotificationEmptyState()
                : Semantics(
                    role: .list,
                    child: ListView.separated(
                      key: const PageStorageKey<String>('notification-history'),
                      itemCount: records.length,
                      padding: const EdgeInsets.only(bottom: 6),
                      separatorBuilder: (_, _) => const SizedBox(height: 9),
                      itemBuilder: (context, index) {
                        final record = records[index];
                        final notification = record.notification;
                        return RepaintBoundary(
                          key: ValueKey<int>(notification.id),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              NotificationCard(
                                notification: notification,
                                compact: true,
                                onDismiss: () => controller.dismissFromHistory(
                                  notification.id,
                                ),
                                onDefaultAction: record.active
                                    ? () => controller.invokeDefaultAction(
                                        notification.id,
                                      )
                                    : null,
                                onAction: record.active
                                    ? (actionKey) => controller.invokeAction(
                                        notification.id,
                                        actionKey,
                                      )
                                    : null,
                              ),
                              if (!record.active)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 4,
                                    right: 8,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      _closeReasonLabel(
                                        record.closeReason,
                                        context.l10n,
                                      ),
                                      style: ShellText.base.copyWith(
                                        color: context.shellColors.textTertiary,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _NotificationCenterHeader extends StatelessWidget {
  const _NotificationCenterHeader({
    required this.showTitle,
    required this.unreadCount,
    required this.doNotDisturb,
    required this.policyLoaded,
    required this.hasNotifications,
    required this.onToggleDoNotDisturb,
    required this.onClearAll,
  });

  final bool showTitle;
  final int unreadCount;
  final bool doNotDisturb;
  final bool policyLoaded;
  final bool hasNotifications;
  final VoidCallback onToggleDoNotDisturb;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        if (showTitle) ...[
          Text(l10n.notificationsTitle, style: ShellText.cardTitle),
          const SizedBox(width: 8),
        ],
        if (unreadCount > 0)
          Semantics(
            label: l10n.notificationsUnread(unreadCount),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.shellTheme.accentPalette.container,
                borderRadius: context.shellTheme.borderRadius(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                child: Text(
                  l10n.numberValue(unreadCount),
                  style: ShellText.base.copyWith(
                    color: context.shellTheme.accentPalette.onContainer,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        _CenterIconButton(
          label: policyLoaded
              ? (doNotDisturb
                    ? l10n.notificationsDisableDoNotDisturb
                    : l10n.notificationsEnableDoNotDisturb)
              : l10n.notificationsLoadingPolicy,
          icon: doNotDisturb
              ? Icons.notifications_off_rounded
              : Icons.notifications_active_rounded,
          active: doNotDisturb,
          enabled: policyLoaded,
          onPressed: onToggleDoNotDisturb,
        ),
        const SizedBox(width: 7),
        _CenterIconButton(
          label: l10n.notificationsClearAll,
          icon: Icons.clear_all_rounded,
          enabled: hasNotifications,
          onPressed: onClearAll,
        ),
      ],
    );
  }
}

class _PrivacyModeSelector extends StatelessWidget {
  const _PrivacyModeSelector({
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final NotificationPreviewMode selected;
  final bool enabled;
  final ValueChanged<NotificationPreviewMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = Text(
      l10n.notificationsOnLockScreen,
      style: ShellText.base.copyWith(
        color: context.shellColors.textTertiary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    );
    final choices = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        for (final mode in NotificationPreviewMode.values) ...[
          Flexible(
            child: _PrivacyChoice(
              mode: mode,
              selected: selected == mode,
              enabled: enabled,
              onPressed: () => onSelected(mode),
            ),
          ),
          if (mode != NotificationPreviewMode.values.last)
            const SizedBox(width: 5),
        ],
      ],
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      role: .radioGroup,
      label: l10n.notificationsLockPrivacy,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 390 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.35;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [label, const SizedBox(height: 7), choices],
            );
          }
          return Row(
            children: [
              label,
              const SizedBox(width: 10),
              Expanded(child: choices),
            ],
          );
        },
      ),
    );
  }
}

class _PrivacyChoice extends StatefulWidget {
  const _PrivacyChoice({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final NotificationPreviewMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_PrivacyChoice> createState() => _PrivacyChoiceState();
}

class _PrivacyChoiceState extends State<_PrivacyChoice> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = switch (widget.mode) {
      NotificationPreviewMode.hidden => l10n.notificationsPreviewHidden,
      NotificationPreviewMode.applicationOnly =>
        l10n.notificationsPreviewApplicationOnly,
      NotificationPreviewMode.full => l10n.notificationsPreviewFull,
    };
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      selected: widget.selected,
      inMutuallyExclusiveGroup: true,
      enabled: widget.enabled,
      label: l10n.notificationsPreviewModeSemantics(label),
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.enabled) {
                widget.onPressed();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            height: 29,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected
                  ? context.shellTheme.accentPalette.container
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: context.shellTheme.borderRadius(10),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
              ),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: widget.enabled
                    ? (widget.selected
                          ? context.shellTheme.accentPalette.onContainer
                          : context.shellColors.textSecondary)
                    : context.shellColors.glyphInactive,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoNotDisturbNotice extends StatelessWidget {
  const _DoNotDisturbNotice();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.notificationsDoNotDisturbSemantics,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellTheme.accentPalette.mutedContainer,
          borderRadius: context.shellTheme.borderRadius(12),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.notifications_off_rounded,
                size: 16,
                color: context.shellTheme.accentPalette.onMutedContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.notificationsQuietMode,
                  style: ShellText.base.copyWith(
                    color: context.shellTheme.accentPalette.onMutedContainer,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationEmptyState extends StatelessWidget {
  const _NotificationEmptyState();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.notificationsNone,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_none_rounded,
              size: 34,
              color: context.shellColors.textTertiary,
            ),
            const SizedBox(height: 9),
            Text(
              context.l10n.notificationsAllQuiet,
              style: ShellText.cardTitle.copyWith(
                color: context.shellColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.notificationsEmptyDescription,
              style: ShellText.base.copyWith(
                color: context.shellColors.textTertiary,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterIconButton extends StatefulWidget {
  const _CenterIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final bool enabled;

  @override
  State<_CenterIconButton> createState() => _CenterIconButtonState();
}

class _CenterIconButtonState extends State<_CenterIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: widget.active,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.enabled) {
                widget.onPressed();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: widget.active
                  ? context.shellTheme.accentPalette.container
                  : _hovered || _focused
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: context.shellTheme.borderRadius(12),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: widget.enabled
                  ? (widget.active
                        ? context.shellTheme.accentPalette.onContainer
                        : context.shellColors.textSecondary)
                  : context.shellColors.glyphInactive,
            ),
          ),
        ),
      ),
    );
  }
}

String _closeReasonLabel(int reason, AppLocalizations l10n) => switch (reason) {
  1 => l10n.notificationsExpired,
  2 => l10n.notificationsDismissed,
  3 => l10n.notificationsClosedByApplication,
  _ => l10n.notificationsClosed,
};
