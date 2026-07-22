import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart'
    show CircularProgressIndicator, IconData, Icons, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../input/shell_interaction_registry.dart';
import '../../services/logind_service.dart';
import '../../state/session_power.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../main_output_centered_surface.dart';
import '../shell_surface_host.dart';

void showPowerSessionSurface(WidgetRef ref) {
  unawaited(ref.read(sessionPowerProvider.notifier).refresh());
  ref
      .read(shellSurfaceControllerProvider.notifier)
      .show(
        keyName: 'power-and-session',
        debugLabel: 'Power and session controls',
        pointerPolicy: ShellPointerPolicy.fullScene,
        keyboardPolicy: ShellKeyboardPolicy.capture,
        dismissPolicy: ShellDismissPolicy.outsideTapAndEscape,
        builder: (_, handle) => PowerSessionSurface(onClose: handle.close),
      );
}

class PowerSessionSurface extends ConsumerWidget {
  const PowerSessionSurface({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionPowerProvider);
    final controller = ref.read(sessionPowerProvider.notifier);
    final confirmationAction = state.confirmationAction;
    final theme = ShellTheme.of(context);
    return MainOutputCenteredSurface(
      padding: const EdgeInsets.all(20),
      builder: (context, constraints) {
        final width = math.min(560.0, constraints.maxWidth);
        final height = math.min(680.0, constraints.maxHeight);
        return SizedBox(
          width: width,
          height: height,
          child: Semantics(
            label: 'Power and session controls',
            container: true,
            explicitChildNodes: true,
            role: confirmationAction == null ? .dialog : .alertDialog,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.panelColor(ShellColors.panelBackground),
                borderRadius: BorderRadius.circular(theme.panelRadius),
                border: Border.all(color: ShellColors.hairline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: ShellColors.shadow,
                    blurRadius: 36,
                    spreadRadius: 3,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: FocusTraversalGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _PowerHeader(
                        busy: state.busy,
                        onRefresh: () => unawaited(controller.refresh()),
                        onClose: onClose,
                      ),
                      const SizedBox(height: 14),
                      if (state.error case final error?) ...<Widget>[
                        _PowerNotice(
                          key: const ValueKey<String>('session-power-error'),
                          icon: Icons.error_outline_rounded,
                          message: error,
                          color: ShellColors.performanceBad,
                          actionLabel: 'Dismiss',
                          onAction: controller.clearError,
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (state.initialized &&
                          !state.snapshot.serviceAvailable) ...<Widget>[
                        const _PowerNotice(
                          key: ValueKey<String>('session-power-unavailable'),
                          icon: Icons.cloud_off_rounded,
                          message:
                              'System power controls are unavailable. Lock and log out remain local to Denial.',
                          color: ShellColors.textSecondary,
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (_delayNotice(state.snapshot) case final delay?) ...[
                        _PowerNotice(
                          key: const ValueKey<String>(
                            'session-power-delay-inhibitor',
                          ),
                          icon: Icons.hourglass_bottom_rounded,
                          message: delay,
                          color: ShellColors.textSecondary,
                        ),
                        const SizedBox(height: 10),
                      ],
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : Motion.cardSettle,
                          switchInCurve: Motion.md3EmphasizedDecelerate,
                          switchOutCurve: Motion.md3EmphasizedAccelerate,
                          child: confirmationAction != null
                              ? _ConfirmationPane(
                                  key: ValueKey<String>(
                                    'confirm-${confirmationAction.name}',
                                  ),
                                  action: confirmationAction,
                                  onCancel: controller.cancelConfirmation,
                                  onConfirm: () =>
                                      unawaited(controller.confirm()),
                                )
                              : _ActionList(
                                  key: const ValueKey<String>(
                                    'session-power-actions',
                                  ),
                                  state: state,
                                  onAction: (action) =>
                                      unawaited(controller.request(action)),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PowerHeader extends StatelessWidget {
  const _PowerHeader({
    required this.busy,
    required this.onRefresh,
    required this.onClose,
  });

  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(
            dimension: 42,
            child: Icon(
              Icons.power_settings_new_rounded,
              size: 22,
              color: ShellColors.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Power & session',
                style: ShellText.statusClock.copyWith(fontSize: 21),
              ),
              const SizedBox(height: 3),
              Text(
                busy ? 'Completing system request…' : 'Choose what Denial does',
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        _PowerIconButton(
          label: 'Refresh power capabilities',
          icon: Icons.refresh_rounded,
          enabled: !busy,
          onPressed: onRefresh,
        ),
        const SizedBox(width: 7),
        _PowerIconButton(
          label: 'Close power and session controls',
          icon: Icons.close_rounded,
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _ActionList extends StatelessWidget {
  const _ActionList({required this.state, required this.onAction, super.key});

  final SessionPowerState state;
  final ValueChanged<SessionPowerAction> onAction;

  static const List<SessionPowerAction> _actions = <SessionPowerAction>[
    SessionPowerAction.lock,
    SessionPowerAction.suspend,
    SessionPowerAction.hibernate,
    SessionPowerAction.logout,
    SessionPowerAction.reboot,
    SessionPowerAction.powerOff,
  ];

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      primary: false,
      padding: EdgeInsets.zero,
      itemCount: _actions.length + (state.initialized ? 0 : 1),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (!state.initialized && index == 0) {
          return const _PowerNotice(
            key: ValueKey<String>('session-power-loading'),
            icon: Icons.sync_rounded,
            message: 'Reading system capabilities and inhibitors…',
            color: ShellColors.textSecondary,
            busy: true,
          );
        }
        final action = _actions[index - (state.initialized ? 0 : 1)];
        final availability = state.availabilityFor(action);
        return _SessionActionTile(
          action: action,
          availability: availability,
          enabled: !state.busy && availability.enabled,
          busy: state.busyAction == action,
          onPressed: () => onAction(action),
        );
      },
    );
  }
}

class _SessionActionTile extends StatefulWidget {
  const _SessionActionTile({
    required this.action,
    required this.availability,
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  final SessionPowerAction action;
  final SessionActionAvailability availability;
  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  @override
  State<_SessionActionTile> createState() => _SessionActionTileState();
}

class _SessionActionTileState extends State<_SessionActionTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final accent = ShellTheme.of(context).accent;
    final reason = widget.availability.unavailableReason;
    final subtitle =
        reason ??
        (widget.availability.requiresAuthentication
            ? 'Authentication required · ${_actionSubtitle(action)}'
            : _actionSubtitle(action));
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: _actionLabel(action),
      hint: subtitle,
      child: Tooltip(
        message: subtitle,
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
                  : Motion.tile,
              constraints: const BoxConstraints(minHeight: 70),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              decoration: BoxDecoration(
                color: widget.enabled
                    ? ShellColors.surfaceContainerHigh
                    : ShellColors.tileOff,
                borderRadius: BorderRadius.circular(ShellRadii.tileWide),
                border: Border.all(
                  color: _focused ? accent : ShellColors.hairlineSoft,
                  width: _focused ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: <Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.enabled
                          ? ShellColors.primaryContainer
                          : ShellColors.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox.square(
                      dimension: 42,
                      child: widget.busy
                          ? Padding(
                              padding: const EdgeInsets.all(12),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : Icon(
                              _actionIcon(action),
                              size: 21,
                              color: widget.enabled
                                  ? ShellColors.onPrimaryContainer
                                  : ShellColors.textTertiary,
                            ),
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          _actionLabel(action),
                          style: ShellText.cardTitle.copyWith(
                            color: widget.enabled
                                ? ShellColors.panelText
                                : ShellColors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ShellText.base.copyWith(
                            color: reason == null
                                ? ShellColors.textSecondary
                                : ShellColors.textTertiary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (action.requiresConfirmation)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: ShellColors.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmationPane extends StatelessWidget {
  const _ConfirmationPane({
    required this.action,
    required this.onCancel,
    required this.onConfirm,
    super.key,
  });

  final SessionPowerAction action;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    return SingleChildScrollView(
      primary: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(theme.panelRadius),
          border: Border.all(color: ShellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DecoratedBox(
                decoration: const BoxDecoration(
                  color: ShellColors.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 58,
                  child: Icon(
                    _actionIcon(action),
                    size: 28,
                    color: ShellColors.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _confirmationTitle(action),
                textAlign: TextAlign.center,
                style: ShellText.statusClock.copyWith(fontSize: 21),
              ),
              const SizedBox(height: 9),
              Text(
                _confirmationBody(action),
                textAlign: TextAlign.center,
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _PowerTextButton(
                      label: 'Cancel',
                      onPressed: onCancel,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PowerTextButton(
                      label: _actionLabel(action),
                      emphasized: true,
                      onPressed: onConfirm,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PowerNotice extends StatelessWidget {
  const _PowerNotice({
    required this.icon,
    required this.message,
    required this.color,
    this.actionLabel,
    this.onAction,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final String message;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: ShellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            if (busy)
              SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent),
              )
            else
              Icon(icon, size: 17, color: color),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: ShellText.base.copyWith(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(width: 8),
              _PowerTextButton(
                label: actionLabel!,
                compact: true,
                onPressed: onAction!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PowerIconButton extends StatefulWidget {
  const _PowerIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  State<_PowerIconButton> createState() => _PowerIconButtonState();
}

class _PowerIconButtonState extends State<_PowerIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused ? accent : ShellColors.hairlineSoft,
                ),
              ),
              child: SizedBox.square(
                dimension: 38,
                child: Icon(
                  widget.icon,
                  size: 19,
                  color: widget.enabled
                      ? ShellColors.panelText
                      : ShellColors.textTertiary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PowerTextButton extends StatefulWidget {
  const _PowerTextButton({
    required this.label,
    required this.onPressed,
    this.emphasized = false,
    this.compact = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool emphasized;
  final bool compact;

  @override
  State<_PowerTextButton> createState() => _PowerTextButtonState();
}

class _PowerTextButtonState extends State<_PowerTextButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
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
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.emphasized
                  ? ShellColors.primaryContainer
                  : ShellColors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? accent : ShellColors.hairlineSoft,
              ),
            ),
            child: SizedBox(
              height: widget.compact ? 32 : 44,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 10 : 14,
                  ),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.base.copyWith(
                      color: widget.emphasized
                          ? ShellColors.onPrimaryContainer
                          : ShellColors.panelText,
                      fontSize: widget.compact ? 10 : 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _delayNotice(LogindSnapshot snapshot) {
  final delays = snapshot.inhibitors
      .where((inhibitor) => inhibitor.mode == 'delay')
      .map((inhibitor) => inhibitor.description)
      .toSet()
      .take(2)
      .toList(growable: false);
  if (delays.isEmpty) {
    return null;
  }
  return 'An application may briefly delay sleep or shutdown: ${delays.join('; ')}';
}

String _actionLabel(SessionPowerAction action) => switch (action) {
  SessionPowerAction.lock => 'Lock',
  SessionPowerAction.logout => 'Log out',
  SessionPowerAction.suspend => 'Suspend',
  SessionPowerAction.hibernate => 'Hibernate',
  SessionPowerAction.reboot => 'Restart',
  SessionPowerAction.powerOff => 'Power off',
};

String _actionSubtitle(SessionPowerAction action) => switch (action) {
  SessionPowerAction.lock => 'Secure the session immediately',
  SessionPowerAction.logout => 'Close the Denial session',
  SessionPowerAction.suspend => 'Keep the session in memory',
  SessionPowerAction.hibernate => 'Save the session to disk',
  SessionPowerAction.reboot => 'Restart the computer',
  SessionPowerAction.powerOff => 'Shut down the computer',
};

IconData _actionIcon(SessionPowerAction action) => switch (action) {
  SessionPowerAction.lock => Icons.lock_rounded,
  SessionPowerAction.logout => Icons.logout_rounded,
  SessionPowerAction.suspend => Icons.bedtime_rounded,
  SessionPowerAction.hibernate => Icons.ac_unit_rounded,
  SessionPowerAction.reboot => Icons.restart_alt_rounded,
  SessionPowerAction.powerOff => Icons.power_settings_new_rounded,
};

String _confirmationTitle(SessionPowerAction action) => switch (action) {
  SessionPowerAction.logout => 'Log out of Denial?',
  SessionPowerAction.reboot => 'Restart the computer?',
  SessionPowerAction.powerOff => 'Power off the computer?',
  _ => _actionLabel(action),
};

String _confirmationBody(SessionPowerAction action) => switch (action) {
  SessionPowerAction.logout =>
    'Your graphical session will end. Save work in open applications before continuing.',
  SessionPowerAction.reboot =>
    'All applications will be closed and the operating system will restart.',
  SessionPowerAction.powerOff =>
    'All applications will be closed and the computer will shut down.',
  _ => '',
};
