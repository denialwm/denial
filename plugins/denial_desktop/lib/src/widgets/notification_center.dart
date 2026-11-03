import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../state/notification_groups.dart';
import 'notification_banner.dart';
import 'notification_rows.dart';

class NotificationCenter extends ConsumerStatefulWidget {
  const NotificationCenter({
    super.key,
    this.showTitle = true,
    this.active = true,
  });

  final bool showTitle;

  /// Only mark history read while the hosting panel is fully visible.
  final bool active;

  @override
  ConsumerState<NotificationCenter> createState() => _NotificationCenterState();
}

class _NotificationCenterState extends ConsumerState<NotificationCenter> {
  bool _markReadScheduled = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopNotificationsProvider);
    final controller = ref.read(desktopNotificationsProvider.notifier);
    final policyLoaded =
        ref.watch(shellSettingsSyncStatusProvider).phase ==
        ShellSettingsSyncPhase.ready;
    final rows = notificationHistoryRows(
      state.groups,
      ref.watch(expandedNotificationGroupsProvider),
    );
    final groups = ref.read(expandedNotificationGroupsProvider.notifier);
    if (widget.active && state.unreadCount > 0 && !_markReadScheduled) {
      _markReadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _markReadScheduled = false;
        if (mounted && widget.active) {
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
            policyLoaded: policyLoaded,
            canClear: state.active.values.any(
              (notification) => notification.clearable,
            ),
            onToggleDoNotDisturb: controller.toggleDoNotDisturb,
            onClearAll: controller.clearAll,
          ),
          const SizedBox(height: 10),
          _PrivacyModeSelector(
            selected: state.lockPreview,
            enabled: policyLoaded,
            onSelected: controller.setLockPreview,
          ),
          const SizedBox(height: 10),
          if (state.doNotDisturb)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: _DoNotDisturbNotice(),
            ),
          Expanded(
            child: rows.isEmpty
                ? const _NotificationEmptyState()
                : Semantics(
                    role: .list,
                    child: ListView.separated(
                      key: const PageStorageKey<String>('notification-history'),
                      itemCount: rows.length,
                      padding: const EdgeInsets.only(bottom: 6),
                      separatorBuilder: (_, _) => const SizedBox(height: 9),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return RepaintBoundary(
                          key: ValueKey<Object>(row.key),
                          child: switch (row) {
                            NotificationGroupHeaderRow(:final group) =>
                              _NotificationGroupHeader(
                                group: group,
                                onCollapse: () => groups.collapse(group.key),
                              ),
                            NotificationGroupRow(:final group) =>
                              DesktopNotificationSwipeDismiss(
                                enabled: group.clearable,
                                onDismiss: () => controller
                                    .dismissGroupFromHistory(group.key),
                                child: NotificationCard(
                                  notification: group.newest.notification,
                                  compact: true,
                                  group: group,
                                  onExpandGroup: () => groups.expand(group.key),
                                ),
                              ),
                            NotificationRow(:final record) =>
                              DesktopNotificationSwipeDismiss(
                                enabled: record.notification.clearable,
                                onDismiss: () => controller.dismissFromHistory(
                                  record.notification.id,
                                ),
                                child: NotificationCard(
                                  notification: record.notification,
                                  compact: true,
                                  onDefaultAction: () => openNotification(
                                    ref,
                                    record.notification.id,
                                  ),
                                  onAction: (actionKey) =>
                                      controller.invokeAction(
                                        record.notification.id,
                                        actionKey,
                                      ),
                                ),
                              ),
                          },
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
    required this.canClear,
    required this.onToggleDoNotDisturb,
    required this.onClearAll,
  });

  final bool showTitle;
  final int unreadCount;
  final bool doNotDisturb;
  final bool policyLoaded;
  final bool canClear;
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
          enabled: canClear,
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

/// Above an opened group's members: its app and count, and a button that
/// folds it back into one card.
class _NotificationGroupHeader extends StatelessWidget {
  const _NotificationGroupHeader({
    required this.group,
    required this.onCollapse,
  });

  final DesktopNotificationGroup group;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final appName = notificationAppName(group.newest.notification, l10n);
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.notificationGroupHeader(appName, group.members.length),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: context.shellColors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
          _CenterIconButton(
            label: l10n.notificationGroupCollapse(appName),
            icon: Icons.expand_less_rounded,
            onPressed: onCollapse,
          ),
        ],
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
